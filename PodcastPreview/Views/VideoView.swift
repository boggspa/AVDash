//
//  VideoView.swift
//  PodcastPreview
//
//  Video Mode UI
//

import SwiftUI
import PodcastPreviewShared
import AVFoundation
import Metal
import MetalKit
import Combine
import UniformTypeIdentifiers
import PodcastPreviewCore

// MARK: - VideoView

private enum VideoPreviewSurfaceMode: String, CaseIterable, Identifiable {
    case preview = "Preview"
    case multiview = "Multiview"

    var id: String { rawValue }
}

private enum MultiviewGridLayout: String, CaseIterable, Identifiable {
    case oneUp = "1x1"
    case twoByTwo = "2x2"
    case fourByFour = "4x4"

    var id: String { rawValue }

    var columns: Int {
        switch self {
        case .oneUp:
            return 1
        case .twoByTwo:
            return 2
        case .fourByFour:
            return 4
        }
    }

    var slotCount: Int {
        switch self {
        case .oneUp:
            return 1
        case .twoByTwo:
            return 4
        case .fourByFour:
            return 16
        }
    }
}

private struct MultiviewSlot: Identifiable, Equatable {
    let id: Int
    var selectedUniqueID: String? = nil
}

private struct FocusPeakingProfileState {
    var isEnabled: Bool = false
    var settings = FocusPeakingSettings()
}

private struct VideoSourceProfileState {
    var preview = CameraMetalPreviewModel.PersistedState()
    var focusPeaking = FocusPeakingProfileState()
}

struct VideoView: View {

    @Environment(\.appUIScale) private var appUIScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.floatingMonitorSource) private var floatingMonitorSource
    private let topHeadroom: CGFloat = 70
    @StateObject private var videoModel = VideoMonitoringModel()
    @StateObject private var metalPreview = CameraMetalPreviewModel()
    @StateObject private var audioManager = MultiDeviceAudioManager()

    // Focus peaking only available on macOS 14.0+ (requires @Observable macro)
    @State private var focusPeakingEngine: Any? = {
        if #available(macOS 14.0, *) {
            do {
                return try FocusPeakingEngine()
            } catch {
                print("Failed to initialize FocusPeakingEngine: \(error)")
                return nil
            }
        }
        return nil
    }()

    // White balance analysis
    @State private var whiteBalanceAnalyzer: WhiteBalanceAnalyzer?
    @State private var whiteBalanceResult: WhiteBalanceAnalyzer.WhiteBalanceResult?
    @State private var whiteBalanceResultsBySource: [String: WhiteBalanceAnalyzer.WhiteBalanceResult] = [:]
    @State private var isAnalyzingWB = false

    // Exposure analysis
    @State private var exposureResult: ExposureAnalyzer.Result?
    @State private var exposureResultsBySource: [String: ExposureAnalyzer.Result] = [:]
    @State private var isAnalyzingExposure = false

    // Frame snapshot
    @State private var snapshotFeedback = false
    @State private var previewSurfaceMode: VideoPreviewSurfaceMode = .preview
    @State private var multiviewGridLayout: MultiviewGridLayout = .twoByTwo
    @State private var multiviewSlots: [MultiviewSlot] = (0..<16).map { MultiviewSlot(id: $0) }
    @State private var sourceProfiles: [String: VideoSourceProfileState] = [:]
    @State private var activeProfileSourceID: String? = nil
    @State private var draggedMultiviewSlotID: Int? = nil

    private var scaledOuterSpacing: CGFloat { 16 * appUIScale }
    private var scaledTopRowSpacing: CGFloat { 12 * appUIScale }
    private var scaledCardInnerSpacing: CGFloat { 10 }
    private var scaledPlaceholderSpacing: CGFloat { 8 * appUIScale }
    private var scaledCPUPlaceholderSpacing: CGFloat { 6 * appUIScale }
    private var scaledBottomScopesSpacing: CGFloat { 16 * appUIScale }
    private var scaledHorizontalPadding: CGFloat { 12 * appUIScale }
    private var scaledTopPadding: CGFloat { 30 * appUIScale }
    private var scaledBottomPadding: CGFloat { 1 * appUIScale }
    private var panelBackgroundFill: Color {
        colorScheme == .light ? Color.black.opacity(0.12) : Color.black.opacity(0.5)
    }
    private var scaledPreviewCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPreviewPlaceholderIconSize: CGFloat { 28 * appUIScale }
    private var scaledScopePlaceholderIconSize: CGFloat { 20 * appUIScale }
    private var scaledScopeHeightParade: CGFloat { 160 }
    private var scaledScopeHeightVectorscope: CGFloat { 160 }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var supportsInteractivePreviewTools: Bool {
        videoModel.previewMode == .metal && videoModel.isDataOutputActive
    }
    private var selectedCameraTitle: String {
        videoModel.selectedDisplayName ?? "No Camera Selected"
    }
    private var activeCameraBinding: Binding<String?> {
        Binding(
            get: { videoModel.selectedUniqueID },
            set: { newValue in
                selectActiveCamera(uniqueID: newValue, initiatedFromToolbar: true)
            }
        )
    }
    private var multiviewColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: scaledCardInnerSpacing), count: multiviewGridLayout.columns)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VideoSidebarView(videoModel: videoModel, metalPreview: metalPreview, audioManager: audioManager)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: scaledOuterSpacing) {

                        // ── Toolbar: pickers + status ──────────────────────────────────
                        HStack(alignment: .center, spacing: scaledTopRowSpacing) {
                            Text("Camera")
                                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))

                            Picker("Camera", selection: activeCameraBinding) {
                                Text("None Selected").tag(nil as String?)
                                ForEach(videoModel.devices) { device in
                                    Text(device.displayName).tag(device.uniqueID as String?)
                                }
                            }
                            .pickerStyle(.menu)

                            Text("Format")
                                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                                .padding(.leading, 8)

                            Picker("Format", selection: $videoModel.formatPreference) {
                                ForEach(VideoMonitoringModel.FormatPreference.allCases) { pref in
                                    Text(pref.displayName).tag(pref)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minWidth: 180)
                            .onChange(of: videoModel.formatPreference) { _ in videoModel.formatPreferenceChanged() }
                            .help("Choose video format: Auto tries all formats, NV12 for modern systems, BGRA for older Intel Macs")

                            Text("Renderer")
                                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                                .padding(.leading, 8)

                            Picker("Preview", selection: $videoModel.previewMode) {
                                ForEach(VideoMonitoringModel.PreviewMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minWidth: 180)
                            .onChange(of: videoModel.previewMode) { _ in videoModel.previewModeChanged() }
                            .help("Metal: GPU rendering with scopes. Native: Apple's preview layer (most compatible on Big Sur)")

                            Spacer(minLength: 0)

                            VStack(alignment: .trailing, spacing: 2 * appUIScale) {
                                Text(videoModel.status.label)
                                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                                Text("\(videoModel.videoResolutionText) • \(videoModel.videoFPSText)")
                                    .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }
                        }

                        // ── Preview Card (full-width) ──────────────────────────────────
                        previewCardContent(showSnapshotButton: true)
                            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledPreviewCornerRadius, style: .continuous))
                            .contextMenu {
                                Button("Add to Custom Stack") {
                                    addPreviewToCustomStack()
                                }

                                Button("Open Floating Card") {
                                    openPreviewFloatingCard()
                                }
                            }

                        VStack(alignment: .leading, spacing: scaledOuterSpacing) {
                            // ── Scopes Card ────────────────────────────────────────────────
                            scopesCardContent()
                                .contentShape(ThemeRoundedRectangle(cornerRadius: scaledPreviewCornerRadius, style: .continuous))
                                .contextMenu {
                                    Button("Add to Custom Stack") {
                                        addScopesToCustomStack()
                                    }

                                    Button("Open Floating Card") {
                                        openScopesFloatingCard()
                                    }
                                }

                            // ── Per-camera control cards (only while running) ──────────────
                            if videoModel.selectedUniqueID != nil && videoModel.status == .running {

                                // Overlay controls (Metal only)
                                if videoModel.previewMode == .metal {
                                    OverlayControlsView(model: metalPreview)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                // Focus Peaking (macOS 14+)
                                if videoModel.previewMode == .metal,
                                   #available(macOS 14.0, *),
                                   let engine = focusPeakingEngine as? FocusPeakingEngine {
                                    FocusPeakingControlsView(engine: engine)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                // Image Adjustments (Metal only)
                                if videoModel.previewMode == .metal {
                                    ImageAdjustmentsView(model: metalPreview)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                // LUT
                                if videoModel.previewMode == .metal {
                                    LUTControlsView(model: metalPreview)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }

                                if videoModel.previewMode == .metal {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Image(systemName: "lightbulb")
                                                .foregroundColor(.secondary)
                                            Text("White Balance")
                                                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                                        }
                                        Button(action: analyzeWhiteBalance) {
                                            HStack {
                                                Image(systemName: isAnalyzingWB ? "hourglass" : "camera.metering.center.weighted")
                                                Text(isAnalyzingWB ? "Analyzing..." : "Analyse White Balance")
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .disabled(isAnalyzingWB)
                                        .help("Analyze current frame to understand color temperature")

                                        if let result = whiteBalanceResult {
                                            WhiteBalanceIndicatorView(result: result)
                                        }
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.05), stroke: Color.white.opacity(0.1))
                                    )

                                    ExposureAnalysisCard(
                                        isAnalyzing: $isAnalyzingExposure,
                                        result: $exposureResult,
                                        onAnalyze: analyzeExposure
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    rendererRequirementCard()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, scaledHorizontalPadding)
                    .padding(.top, scaledTopPadding + topHeadroom)
                    .padding(.bottom, scaledBottomPadding)
                }
            }

            VideoHealthToolbar(videoModel: videoModel)
        }
        .ignoresSafeArea()
        .onAppear {
            videoModel.refreshDevices()

            videoModel.onFrame = { [weak metalPreview, focusPeakingEngine] pixelBuffer, timestamp in
                if #available(macOS 14.0, *) {
                    metalPreview?.enqueue(pixelBuffer: pixelBuffer, timestamp: timestamp, focusEngine: focusPeakingEngine as AnyObject?)
                } else {
                    metalPreview?.enqueueCompat(pixelBuffer: pixelBuffer, timestamp: timestamp)
                }
            }

            videoModel.onScopeFrame = { [weak metalPreview] pixelBuffer in
                metalPreview?.scopes.enqueue(pixelBuffer: pixelBuffer)
            }

            if #available(macOS 14.0, *) {
                metalPreview.focusPeakingEngine = focusPeakingEngine as AnyObject?
            }

            if let device = metalPreview.device {
                whiteBalanceAnalyzer = WhiteBalanceAnalyzer(device: device)
            }

            restoreProfile(for: videoModel.selectedUniqueID)
            activeProfileSourceID = videoModel.selectedUniqueID
            syncMultiviewSlots(preferredPrimaryID: videoModel.selectedUniqueID)
            draggedMultiviewSlotID = nil
        }
        .onChange(of: videoModel.devices) { _ in
            pruneSourceStateForAvailableDevices()
            syncMultiviewSlots(preferredPrimaryID: videoModel.selectedUniqueID)
        }
        .onChange(of: videoModel.selectedUniqueID) { newValue in
            saveProfile(for: activeProfileSourceID)
            restoreProfile(for: newValue)
            activeProfileSourceID = newValue
            syncMultiviewSlots(preferredPrimaryID: newValue)
        }
        .onDisappear {
            saveProfile(for: activeProfileSourceID)
            videoModel.onFrame = nil
            videoModel.onScopeFrame = nil
            videoModel.stop()
        }
    }
    private var videoCardSource: FloatingMonitorCardSource {
        floatingMonitorSource ?? .local
    }

    @ViewBuilder
    private func previewCardContent(showSnapshotButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: scaledCardInnerSpacing) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview")
                        .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                    Text(previewSurfaceMode == .preview ? selectedCameraTitle : "Compare live cameras and promote one into the main preview")
                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(videoModel.previewMode.rawValue)
                    .font(.system(size: scaledCaption2FontSize, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                Picker("Surface", selection: $previewSurfaceMode) {
                    ForEach(VideoPreviewSurfaceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                if previewSurfaceMode == .multiview {
                    Picker("Grid", selection: $multiviewGridLayout) {
                        ForEach(MultiviewGridLayout.allCases) { layout in
                            Text(layout.rawValue).tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 74)
                }
                if showSnapshotButton && videoModel.status == .running && previewSurfaceMode == .preview && supportsInteractivePreviewTools {
                    Button(action: captureSnapshot) {
                        Image(systemName: snapshotFeedback ? "checkmark.circle.fill" : "camera.fill")
                            .font(.system(size: 13))
                            .foregroundColor(snapshotFeedback ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy current frame to clipboard")
                }
            }
            .padding(.top, scaledCardInnerSpacing)
            .padding(.horizontal, scaledCardInnerSpacing)

            if previewSurfaceMode == .multiview {
                LazyVGrid(columns: multiviewColumns, spacing: scaledCardInnerSpacing) {
                    ForEach(Array(multiviewSlots.prefix(multiviewGridLayout.slotCount).enumerated()), id: \.element.id) { entry in
                        let index = entry.offset
                        let slot = entry.element
                        MultiviewPreviewTile(
                            slotID: slot.id,
                            selectedUniqueID: multiviewSelectionBinding(for: index),
                            devices: videoModel.devices,
                            sharedSession: videoModel.session,
                            unavailableUniqueIDs: Set(multiviewSlots.enumerated().compactMap { offset, slot in
                                offset == index ? nil : slot.selectedUniqueID
                            }),
                            activePreviewModel: videoModel.previewMode == .metal ? metalPreview : nil,
                            isActiveSelection: multiviewSlots[index].selectedUniqueID != nil &&
                                multiviewSlots[index].selectedUniqueID == videoModel.selectedUniqueID,
                            sourceProfile: multiviewSlots[index].selectedUniqueID.flatMap { sourceProfiles[$0] },
                            draggedSlotID: $draggedMultiviewSlotID,
                            onActivate: {
                                activateMultiviewSlot(index)
                            }
                        )
                        .opacity(draggedMultiviewSlotID == slot.id ? 0.45 : 1)
                        .scaleEffect(draggedMultiviewSlotID == slot.id ? 0.98 : 1)
                        .onDrop(
                            of: [UTType.plainText.identifier],
                            delegate: MultiviewTileReorderDropDelegate(
                                destinationIndex: index,
                                destinationSlotID: slot.id,
                                slots: $multiviewSlots,
                                draggedSlotID: $draggedMultiviewSlotID
                            )
                        )
                    }
                }
                .padding([.horizontal, .bottom], scaledCardInnerSpacing)
                .padding(.bottom, scaledCardInnerSpacing)
            } else {
                ZStack {
                    if videoModel.previewMode == .metal {
                        CameraMetalPreviewView(model: metalPreview)
                    } else {
                        NativePreviewLayerView(session: videoModel.session)
                    }
                    if videoModel.selectedUniqueID == nil {
                        VStack(spacing: scaledPlaceholderSpacing) {
                            Image(systemName: "video")
                                .font(.system(size: scaledPreviewPlaceholderIconSize))
                                .foregroundColor(.secondary)
                            Text("None Selected")
                                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                    } else if videoModel.status != .running {
                        VStack(spacing: scaledPlaceholderSpacing) {
                            Image(systemName: "video")
                                .font(.system(size: scaledPreviewPlaceholderIconSize))
                                .foregroundColor(.secondary)
                            Text(videoModel.status.label)
                                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .padding(.horizontal, scaledCardInnerSpacing)
                .padding(.bottom, scaledCardInnerSpacing)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            ThemeRoundedRectangle(cornerRadius: scaledPreviewCornerRadius, style: .continuous).themed(fill: Color.black.opacity(0.05), stroke: Color.white.opacity(0.12))
        )
    }

    @ViewBuilder
    private func scopesCardContent() -> some View {
        VStack(alignment: .leading, spacing: scaledCardInnerSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scopes")
                    .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                Text(supportsInteractivePreviewTools ? selectedCameraTitle : "Switch the renderer to Metal and start a camera to drive the scopes")
                    .font(.system(size: scaledCaption2FontSize, weight: .regular))
                    .foregroundColor(.secondary)
            }
                .padding(.top, scaledCardInnerSpacing)
                .padding(.horizontal, scaledCardInnerSpacing)

            if supportsInteractivePreviewTools && videoModel.status == .running {
                if videoModel.scopesAvailable {
                    HStack(alignment: .top, spacing: 0) {
                        scopeColumn(title: "Luma", backdropStyle: .waveform, showsScale: true) {
                            VideoScopeMTKView(model: metalPreview.scopes, kind: .waveform)
                        }
                        scopeDivider()
                        scopeColumn(title: "RGB Parade", backdropStyle: .parade, showsScale: true) {
                            VideoScopeMTKView(model: metalPreview.scopes, kind: .parade)
                        }
                        scopeDivider()
                        scopeColumn(title: "Vectorscope", backdropStyle: .vectorscope) {
                            VideoScopeMTKView(model: metalPreview.scopes, kind: .vectorscope)
                        }
                    }
                    .padding(.horizontal, scaledCardInnerSpacing)
                    .padding(.bottom, scaledCardInnerSpacing)
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        scopeColumn(title: "RGB Parade", backdropStyle: .parade, showsScale: true) {
                            if let img = videoModel.cpuParadeImage {
                                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                                    .resizable().interpolation(.none).scaledToFit()
                            } else {
                                scopePlaceholder(icon: "waveform.path.ecg", label: "No signal")
                            }
                        }
                        scopeDivider()
                        scopeColumn(title: "Vectorscope", backdropStyle: .vectorscope) {
                            if let img = videoModel.cpuVectorscopeImage {
                                Image(nsImage: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)))
                                    .resizable().interpolation(.none).scaledToFit()
                            } else {
                                scopePlaceholder(icon: "scope", label: "No signal")
                            }
                        }
                    }
                    .padding(.horizontal, scaledCardInnerSpacing)
                    .padding(.bottom, scaledCardInnerSpacing)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    scopeColumn(title: "Scopes", backdropStyle: .vectorscope) {
                        scopeUnavailableState(
                            icon: videoModel.previewMode == .metal ? "video.slash" : "cpu",
                            title: videoModel.previewMode == .metal ? "Waiting for live frames" : "Metal renderer required",
                            subtitle: videoModel.previewMode == .metal ? "Start a camera to populate the scopes." : "Switch Renderer to Metal to enable scopes, analysis, and snapshot capture."
                        )
                    }
                }
                .padding(.horizontal, scaledCardInnerSpacing)
                .padding(.bottom, scaledCardInnerSpacing)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            ThemeRoundedRectangle(cornerRadius: scaledPreviewCornerRadius, style: .continuous).themed(fill: Color.black.opacity(0.05), stroke: Color.white.opacity(0.12))
        )
    }

    private func previewFloatingCardEntry() -> FloatingCustomMonitorCardEntry {
        FloatingCustomMonitorCardEntry(
            key: "\(videoCardSource.key).video-preview-card",
            title: "Preview",
            windowTitle: "Preview — \(videoCardSource.displayName)",
            defaultContentSize: CGSize(width: 760, height: 520),
            minimumContentSize: CGSize(width: 420, height: 320),
            prefersFullWidthInCustomStack: true,
            content: AnyView(previewCardContent(showSnapshotButton: false))
        )
    }

    private func scopesFloatingCardEntry() -> FloatingCustomMonitorCardEntry {
        FloatingCustomMonitorCardEntry(
            key: "\(videoCardSource.key).video-scopes-card",
            title: "Scopes",
            windowTitle: "Scopes — \(videoCardSource.displayName)",
            defaultContentSize: CGSize(width: 760, height: 420),
            minimumContentSize: CGSize(width: 420, height: 260),
            prefersFullWidthInCustomStack: true,
            content: AnyView(scopesCardContent())
        )
    }

    private func openPreviewFloatingCard() {
        FloatingMonitorWindowController.shared.openCustomCard(previewFloatingCardEntry())
    }

    private func addPreviewToCustomStack() {
        CustomMonitorStackWindowController.shared.addCustomCard(previewFloatingCardEntry(), source: videoCardSource)
    }

    private func openScopesFloatingCard() {
        FloatingMonitorWindowController.shared.openCustomCard(scopesFloatingCardEntry())
    }

    private func addScopesToCustomStack() {
        CustomMonitorStackWindowController.shared.addCustomCard(scopesFloatingCardEntry(), source: videoCardSource)
    }

    // ── Scope layout helpers ───────────────────────────────────────────────

    private enum ScopeBackdropStyle {
        case waveform
        case parade
        case vectorscope
    }

    @ViewBuilder
    private func scopeColumn<Content: View>(title: String, backdropStyle: ScopeBackdropStyle, showsScale: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: scaledCaptionFontSize, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            ZStack(alignment: .leading) {
                scopeBackdrop(backdropStyle)
                if showsScale {
                    scopeScaleOverlay()
                }
                content()
                    .padding(10)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1.0, contentMode: .fit)
        }
        .frame(maxWidth: .infinity)
    }

    private func scopeDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, scaledCardInnerSpacing)
    }

    @ViewBuilder
    private func scopePlaceholder(icon: String, label: String) -> some View {
        Color.clear.overlay(
            VStack(spacing: scaledCPUPlaceholderSpacing) {
                Image(systemName: icon)
                    .font(.system(size: scaledScopePlaceholderIconSize))
                    .foregroundColor(.secondary)
                Text(label)
                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                    .foregroundColor(.secondary)
            }
        )
    }

    @ViewBuilder
    private func scopeUnavailableState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: scaledScopePlaceholderIconSize))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: scaledCaptionFontSize, weight: .semibold))
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func scopeBackdrop(_ style: ScopeBackdropStyle) -> some View {
        switch style {
        case .waveform:
            ThemeRoundedRectangle(cornerRadius: 12).themed(
                fill: Color.clear,
                stroke: Color.white.opacity(0.10)
            )
            .background(
                ThemeRoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.03),
                                Color.black.opacity(0.22)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
        case .parade:
            ThemeRoundedRectangle(cornerRadius: 12).themed(
                fill: Color.clear,
                stroke: Color.white.opacity(0.10)
            )
            .background(
                ThemeRoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color.red.opacity(0.12), location: 0.0),
                                .init(color: Color.red.opacity(0.04), location: 0.333),
                                .init(color: Color.green.opacity(0.12), location: 0.5),
                                .init(color: Color.green.opacity(0.04), location: 0.666),
                                .init(color: Color.blue.opacity(0.12), location: 0.833),
                                .init(color: Color.blue.opacity(0.04), location: 1.0)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
        case .vectorscope:
            ThemeRoundedRectangle(cornerRadius: 12).themed(
                fill: Color.clear,
                stroke: Color.white.opacity(0.10)
            )
            .background(
                ThemeRoundedRectangle(cornerRadius: 12)
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.06),
                                Color.black.opacity(0.10),
                                Color.black.opacity(0.22)
                            ]),
                            center: .center,
                            startRadius: 0,
                            endRadius: 180
                        )
                    )
            )
        }
    }

    private func scopeScaleOverlay() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(["100", "75", "50", "25", "0"].enumerated()), id: \.offset) { item in
                HStack(spacing: 6) {
                    Text(item.element)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(item.offset == 0 || item.offset == 4 ? 0.52 : 0.34))
                    Rectangle()
                        .fill(Color.white.opacity(item.offset == 0 || item.offset == 4 ? 0.22 : 0.10))
                        .frame(width: 8, height: 1)
                    Spacer(minLength: 0)
                }
                if item.offset < 4 {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func rendererRequirementCard() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(.secondary)
                Text("Advanced Tools Unavailable")
                    .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
            }
            Text("Switch the renderer to Metal to enable scopes, focus peaking, LUTs, still capture, white balance analysis, and exposure analysis.")
                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.05), stroke: Color.white.opacity(0.1))
        )
    }

    // MARK: - Helper Functions

    private var visibleMultiviewSlotIndices: [Int] {
        Array(multiviewSlots.indices.prefix(multiviewGridLayout.slotCount))
    }

    private var activeMultiviewSlotIndex: Int? {
        guard let selectedUniqueID = videoModel.selectedUniqueID else { return nil }
        return multiviewSlots.firstIndex(where: { $0.selectedUniqueID == selectedUniqueID })
    }

    private func multiviewSelectionBinding(for index: Int) -> Binding<String?> {
        Binding(
            get: {
                guard multiviewSlots.indices.contains(index) else { return nil }
                return multiviewSlots[index].selectedUniqueID
            },
            set: { newValue in
                assignMultiviewSelection(newValue, to: index, shouldActivate: true)
            }
        )
    }

    private func selectActiveCamera(uniqueID: String?, initiatedFromToolbar: Bool = false) {
        guard previewSurfaceMode == .multiview, initiatedFromToolbar else {
            videoModel.selectCamera(uniqueID: uniqueID)
            return
        }

        let targetIndex = activeMultiviewSlotIndex
            ?? visibleMultiviewSlotIndices.first(where: { multiviewSlots[$0].selectedUniqueID == nil })
            ?? visibleMultiviewSlotIndices.first

        if let targetIndex {
            assignMultiviewSelection(uniqueID, to: targetIndex, shouldActivate: true)
        } else {
            videoModel.selectCamera(uniqueID: uniqueID)
        }
    }

    private func activateMultiviewSlot(_ index: Int) {
        guard multiviewSlots.indices.contains(index),
              let uniqueID = multiviewSlots[index].selectedUniqueID else { return }
        guard uniqueID != videoModel.selectedUniqueID else { return }
        videoModel.selectCamera(uniqueID: uniqueID)
    }

    private func assignMultiviewSelection(_ uniqueID: String?, to index: Int, shouldActivate: Bool) {
        guard multiviewSlots.indices.contains(index) else { return }

        let previousSelection = multiviewSlots[index].selectedUniqueID
        if previousSelection == uniqueID {
            if shouldActivate, let uniqueID {
                videoModel.selectCamera(uniqueID: uniqueID)
            }
            return
        }

        if let uniqueID,
           let existingIndex = multiviewSlots.firstIndex(where: { $0.selectedUniqueID == uniqueID }) {
            multiviewSlots[index].selectedUniqueID = uniqueID
            if existingIndex != index {
                multiviewSlots[existingIndex].selectedUniqueID = previousSelection
            }
        } else {
            multiviewSlots[index].selectedUniqueID = uniqueID
        }

        guard shouldActivate else { return }

        if let uniqueID {
            videoModel.selectCamera(uniqueID: uniqueID)
        } else if videoModel.selectedUniqueID == previousSelection {
            videoModel.selectCamera(uniqueID: nextAvailableMultiviewSelection(excluding: index))
        }
    }

    private func syncMultiviewSlots(preferredPrimaryID: String?) {
        let deviceIDs = videoModel.devices.map(\.uniqueID)
        let availableIDs = Set(deviceIDs)

        guard !multiviewSlots.isEmpty else { return }

        if deviceIDs.isEmpty {
            for index in multiviewSlots.indices {
                multiviewSlots[index].selectedUniqueID = nil
            }
            return
        }

        for index in multiviewSlots.indices {
            if let currentID = multiviewSlots[index].selectedUniqueID,
               !availableIDs.contains(currentID) {
                multiviewSlots[index].selectedUniqueID = nil
            }
        }

        var seenIDs = Set<String>()

        for index in multiviewSlots.indices {
            guard let currentID = multiviewSlots[index].selectedUniqueID else { continue }
            if seenIDs.contains(currentID) {
                multiviewSlots[index].selectedUniqueID = nil
            } else {
                seenIDs.insert(currentID)
            }
        }

        if !multiviewSlots.contains(where: { $0.selectedUniqueID != nil }) {
            var remainingIDs = deviceIDs.makeIterator()
            for index in multiviewSlots.indices where multiviewSlots[index].selectedUniqueID == nil {
                multiviewSlots[index].selectedUniqueID = remainingIDs.next()
            }
        }

        guard let preferredPrimaryID, availableIDs.contains(preferredPrimaryID) else { return }

        if let existingIndex = multiviewSlots.firstIndex(where: { $0.selectedUniqueID == preferredPrimaryID }) {
            guard !visibleMultiviewSlotIndices.contains(existingIndex),
                  let targetIndex = visibleMultiviewSlotIndices.first(where: { multiviewSlots[$0].selectedUniqueID == nil })
                    ?? visibleMultiviewSlotIndices.first else { return }
            multiviewSlots.swapAt(existingIndex, targetIndex)
            return
        }

        guard let targetIndex = visibleMultiviewSlotIndices.first(where: { multiviewSlots[$0].selectedUniqueID == nil })
            ?? visibleMultiviewSlotIndices.first else { return }

        let displacedSelection = multiviewSlots[targetIndex].selectedUniqueID
        multiviewSlots[targetIndex].selectedUniqueID = preferredPrimaryID

        if let displacedSelection,
           let emptyIndex = multiviewSlots.indices.first(where: { $0 != targetIndex && multiviewSlots[$0].selectedUniqueID == nil }) {
            multiviewSlots[emptyIndex].selectedUniqueID = displacedSelection
        }
    }

    private func nextAvailableMultiviewSelection(excluding index: Int) -> String? {
        if let visibleSelection = visibleMultiviewSlotIndices
            .filter({ $0 != index })
            .compactMap({ multiviewSlots[$0].selectedUniqueID })
            .first {
            return visibleSelection
        }

        return multiviewSlots.indices
            .filter({ $0 != index })
            .compactMap({ multiviewSlots[$0].selectedUniqueID })
            .first
    }

    private func moveMultiviewSlot(withID slotID: Int, to destinationIndex: Int) {
        guard let fromIndex = multiviewSlots.firstIndex(where: { $0.id == slotID }),
              multiviewSlots.indices.contains(destinationIndex),
              fromIndex != destinationIndex else { return }

        let movedSlot = multiviewSlots.remove(at: fromIndex)
        multiviewSlots.insert(movedSlot, at: destinationIndex)
    }

    private func currentFocusPeakingProfileState() -> FocusPeakingProfileState {
        if #available(macOS 14.0, *),
           let engine = focusPeakingEngine as? FocusPeakingEngine {
            return FocusPeakingProfileState(isEnabled: engine.isEnabled, settings: engine.settings)
        }

        return FocusPeakingProfileState()
    }

    private func applyFocusPeakingProfileState(_ state: FocusPeakingProfileState) {
        if #available(macOS 14.0, *),
           let engine = focusPeakingEngine as? FocusPeakingEngine {
            engine.isEnabled = state.isEnabled
            engine.settings = state.settings
        }
    }

    private func saveProfile(for uniqueID: String?) {
        guard let uniqueID else { return }

        sourceProfiles[uniqueID] = VideoSourceProfileState(
            preview: metalPreview.persistedState(),
            focusPeaking: currentFocusPeakingProfileState()
        )

        if let whiteBalanceResult {
            whiteBalanceResultsBySource[uniqueID] = whiteBalanceResult
        } else {
            whiteBalanceResultsBySource.removeValue(forKey: uniqueID)
        }

        if let exposureResult {
            exposureResultsBySource[uniqueID] = exposureResult
        } else {
            exposureResultsBySource.removeValue(forKey: uniqueID)
        }
    }

    private func restoreProfile(for uniqueID: String?) {
        let profile = uniqueID.flatMap { sourceProfiles[$0] } ?? VideoSourceProfileState()
        metalPreview.applyPersistedState(profile.preview)
        applyFocusPeakingProfileState(profile.focusPeaking)
        whiteBalanceResult = uniqueID.flatMap { whiteBalanceResultsBySource[$0] }
        exposureResult = uniqueID.flatMap { exposureResultsBySource[$0] }
        isAnalyzingWB = false
        isAnalyzingExposure = false
    }

    private func pruneSourceStateForAvailableDevices() {
        let availableIDs = Set(videoModel.devices.map(\.uniqueID))
        sourceProfiles = sourceProfiles.filter { availableIDs.contains($0.key) }
        whiteBalanceResultsBySource = whiteBalanceResultsBySource.filter { availableIDs.contains($0.key) }
        exposureResultsBySource = exposureResultsBySource.filter { availableIDs.contains($0.key) }

        if let activeProfileSourceID,
           !availableIDs.contains(activeProfileSourceID) {
            self.activeProfileSourceID = nil
        }
    }

    private func analyzeWhiteBalance() {
        guard let pixelBuffer = metalPreview.takeLatestPixelBuffer() else {
            print("Error: White Balance: No pixel buffer available")
            return
        }

        guard let analyzer = whiteBalanceAnalyzer else {
            print("Error: White Balance: Analyzer not initialized")
            return
        }

        print("White Balance: Starting analysis...")
        isAnalyzingWB = true

        // Run on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let result = analyzer.analyze(pixelBuffer: pixelBuffer)

            DispatchQueue.main.async {
                if let result = result {
                    print("Success: White Balance: Temperature \(Int(result.temperature))K, Confidence \(result.confidence)")
                    self.whiteBalanceResult = result
                    if let selectedUniqueID = self.videoModel.selectedUniqueID {
                        self.whiteBalanceResultsBySource[selectedUniqueID] = result
                    }
                } else {
                    print("Error: White Balance: Analysis returned nil")
                    if let selectedUniqueID = self.videoModel.selectedUniqueID {
                        self.whiteBalanceResultsBySource.removeValue(forKey: selectedUniqueID)
                    }
                }
                self.isAnalyzingWB = false
            }
        }
    }

    private func analyzeExposure() {
        guard let pixelBuffer = metalPreview.takeLatestPixelBuffer() else { return }
        isAnalyzingExposure = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ExposureAnalyzer().analyze(pixelBuffer: pixelBuffer)
            DispatchQueue.main.async {
                self.exposureResult = result
                if let selectedUniqueID = self.videoModel.selectedUniqueID {
                    if let result {
                        self.exposureResultsBySource[selectedUniqueID] = result
                    } else {
                        self.exposureResultsBySource.removeValue(forKey: selectedUniqueID)
                    }
                }
                self.isAnalyzingExposure = false
            }
        }
    }

    private func captureSnapshot() {
        guard let pb = metalPreview.takeLatestPixelBuffer() else { return }
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent) else { return }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        snapshotFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { snapshotFeedback = false }
    }
}

// Swift-side mirror of the Metal PreviewUniforms struct — must match layout exactly.
// Defined at file scope so both CameraMetalPreviewModel and its Coordinator can access it.
private struct PreviewUniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var overlayMode: UInt32
    var zebraThreshold: Float
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
    var pad2: UInt32 = 0
}

// MARK: - Metal Preview Model + View

/// Owns the Metal pipeline + CVMetalTextureCache and stores the latest frame.
final class CameraMetalPreviewModel: NSObject, ObservableObject {

    struct PersistedState {
        var overlayMode: PreviewOverlay = .none
        var zebraThreshold: Float = 0.90
        var brightness: Float = 0.0
        var contrast: Float = 1.0
        var saturation: Float = 1.0
        var lutEnabled: Bool = false
        var lutName: String? = nil
        var lutTexture: MTLTexture? = nil
    }

    // Metal core
    fileprivate let device: MTLDevice?
    fileprivate let commandQueue: MTLCommandQueue?
    fileprivate var pipelineState: MTLRenderPipelineState?
    fileprivate var sampler: MTLSamplerState?
    fileprivate var textureCache: CVMetalTextureCache?

    let scopes: VideoScopesModel

    // Focus peaking engine (injected from VideoView)
    // Stored as AnyObject to avoid availability restrictions on the property itself
    weak var focusPeakingEngine: AnyObject?

    // Preview overlay mode
    enum PreviewOverlay: UInt32, CaseIterable {
        case none          = 0
        case framingGuides = 1
        case zebra         = 2
        case falseColor    = 3

        var label: String {
            switch self {
            case .none:          return "None"
            case .framingGuides: return "Guides"
            case .zebra:         return "Zebra"
            case .falseColor:    return "False Color"
            }
        }
        var icon: String {
            switch self {
            case .none:          return "video"
            case .framingGuides: return "grid"
            case .zebra:         return "strikethrough"
            case .falseColor:    return "eyedropper.halffull"
            }
        }
    }

    @Published var overlayMode:     PreviewOverlay = .none
    @Published var zebraThreshold:  Float = 0.90
    @Published var brightness:      Float = 0.0
    @Published var contrast:        Float = 1.0
    @Published var saturation:      Float = 1.0

    /// Callback for processed frames (after LUT/Adjustments)
    var onProcessedFrame: ((CVPixelBuffer, CMTime) -> Void)?
    fileprivate var lastProcessedTimestamp: CMTime = .zero

    // LUT (3D Look-Up Table)
    @Published var lutEnabled: Bool = false
    @Published var lutName: String? = nil
    fileprivate var lutTexture: MTLTexture?

    // Latest pixel buffer (written on capture queue, read on render thread)
    private let frameQueue = DispatchQueue(label: "CameraMetalPreviewModel.frameQueue")
    private var latestPixelBuffer: CVPixelBuffer?

    override init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = self.device?.makeCommandQueue()
        self.scopes = VideoScopesModel(device: self.device)
        super.init()

        guard let device else { return }

        // Texture cache
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache

        // Sampler
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sd.rAddressMode = .clampToEdge       // 3D LUT depth axis
        self.sampler = device.makeSamplerState(descriptor: sd)

        // Pipeline
        buildPipeline(device: device)
    }

    // MARK: - LUT Loading

    /// Load a .cube LUT file and build a 3D Metal texture from it.
    func loadLUT(from url: URL) {
        guard let device else { return }

        do {
            let (size, data) = try Self.parseCubeFile(url: url)
            lutTexture = Self.make3DTexture(device: device, size: size, data: data)
            DispatchQueue.main.async {
                self.lutName = url.deletingPathExtension().lastPathComponent
                self.lutEnabled = true
            }
        } catch {
            print("LUT load error: \(error)")
            DispatchQueue.main.async {
                self.lutName = nil
                self.lutEnabled = false
            }
        }
    }

    /// Remove the currently loaded LUT.
    func removeLUT() {
        lutTexture = nil
        DispatchQueue.main.async {
            self.lutName = nil
            self.lutEnabled = false
        }
    }

    func persistedState() -> PersistedState {
        PersistedState(
            overlayMode: overlayMode,
            zebraThreshold: zebraThreshold,
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            lutEnabled: lutEnabled,
            lutName: lutName,
            lutTexture: lutTexture
        )
    }

    func applyPersistedState(_ state: PersistedState) {
        overlayMode = state.overlayMode
        zebraThreshold = state.zebraThreshold
        brightness = state.brightness
        contrast = state.contrast
        saturation = state.saturation
        lutTexture = state.lutTexture
        lutName = state.lutName
        lutEnabled = state.lutEnabled && state.lutTexture != nil
    }

    /// Parse an Adobe/Resolve .cube file.  Returns (size, [Float]) where
    /// the float array is RGBRGB… with `size^3` entries.
    private static func parseCubeFile(url: URL) throws -> (Int, [Float]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size: Int = 0
        var data: [Float] = []

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("TITLE") ||
               trimmed.hasPrefix("DOMAIN_MIN") || trimmed.hasPrefix("DOMAIN_MAX") {
                continue
            }
            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.split(separator: " ")
                if parts.count >= 2, let s = Int(parts[1]) {
                    size = s
                    data.reserveCapacity(s * s * s * 3)
                }
                continue
            }
            // Data line: "R G B"
            let parts = trimmed.split(separator: " ")
            if parts.count >= 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                data.append(r)
                data.append(g)
                data.append(b)
            }
        }

        guard size >= 2, data.count == size * size * size * 3 else {
            throw NSError(domain: "LUT", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid .cube file (expected \(size)^3 = \(size*size*size) entries, got \(data.count / 3))"])
        }

        return (size, data)
    }

    /// Build a 3D Metal texture from parsed LUT data.
    private static func make3DTexture(device: MTLDevice, size: Int, data: [Float]) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float
        desc.width  = size
        desc.height = size
        desc.depth  = size
        desc.usage  = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        // Convert RGB triples → RGBA quads
        var rgba = [Float](repeating: 0, count: size * size * size * 4)
        for i in 0 ..< size * size * size {
            rgba[i * 4 + 0] = data[i * 3 + 0]
            rgba[i * 4 + 1] = data[i * 3 + 1]
            rgba[i * 4 + 2] = data[i * 3 + 2]
            rgba[i * 4 + 3] = 1.0
        }

        texture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: size, height: size, depth: size)),
            mipmapLevel: 0,
            slice: 0,
            withBytes: rgba,
            bytesPerRow: size * 4 * MemoryLayout<Float>.stride,
            bytesPerImage: size * size * 4 * MemoryLayout<Float>.stride
        )

        return texture
    }

    @available(macOS 14.0, *)
    func enqueue(pixelBuffer: CVPixelBuffer, timestamp: CMTime, focusEngine: AnyObject? = nil) {
        frameQueue.async {
            // Hold a reference to the latest frame only (drop older frames).
            self.latestPixelBuffer = pixelBuffer
            self.lastProcessedTimestamp = timestamp
        }
        // Note: scopes.enqueue moved to separate callback
    }

    /// Compatibility method for older macOS versions (no focus peaking)
    func enqueueCompat(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        frameQueue.async {
            self.latestPixelBuffer = pixelBuffer
            self.lastProcessedTimestamp = timestamp
        }
    }

    fileprivate func takeLatestPixelBuffer() -> CVPixelBuffer? {
        frameQueue.sync {
            return self.latestPixelBuffer
        }
    }

    // Pipeline state for different formats
    fileprivate var pipelineStateNV12: MTLRenderPipelineState?
    fileprivate var pipelineStateBGRA: MTLRenderPipelineState?
    // LUT-enabled pipeline variants
    fileprivate var pipelineStateNV12LUT: MTLRenderPipelineState?
    fileprivate var pipelineStateBGRALUT: MTLRenderPipelineState?

    private func buildPipeline(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared

        // NV12 pipeline
        self.pipelineStateNV12 = compilerCache.pipelineState(
            vertexFunctionName: "nv12QuadVertex",
            fragmentFunctionName: "nv12QuadFragment",
            pixelFormat: .bgra8Unorm,
            blendingMode: .opaque
        )

        // BGRA pipeline (for older Intel Macs)
        self.pipelineStateBGRA = compilerCache.pipelineState(
            vertexFunctionName: "nv12QuadVertex",
            fragmentFunctionName: "bgraQuadFragment",
            pixelFormat: .bgra8Unorm,
            blendingMode: .opaque
        )

        // NV12 + LUT pipeline
        self.pipelineStateNV12LUT = compilerCache.pipelineState(
            vertexFunctionName: "nv12QuadVertex",
            fragmentFunctionName: "nv12LUTQuadFragment",
            pixelFormat: .bgra8Unorm,
            blendingMode: .opaque
        )

        // BGRA + LUT pipeline
        self.pipelineStateBGRALUT = compilerCache.pipelineState(
            vertexFunctionName: "nv12QuadVertex",
            fragmentFunctionName: "bgraLUTQuadFragment",
            pixelFormat: .bgra8Unorm,
            blendingMode: .opaque
        )

        // Default to NV12 pipeline
        self.pipelineState = pipelineStateNV12
    }

    fileprivate func makeNV12Textures(from pixelBuffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Plane 0: Y
        var yTexRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,
            &yTexRef
        )
        guard yStatus == kCVReturnSuccess, let yTexRef, let yTex = CVMetalTextureGetTexture(yTexRef) else { return nil }

        // Plane 1: CbCr (half resolution)
        var uvTexRef: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            width / 2,
            height / 2,
            1,
            &uvTexRef
        )
        guard uvStatus == kCVReturnSuccess, let uvTexRef, let uvTex = CVMetalTextureGetTexture(uvTexRef) else { return nil }

        return (yTex, uvTex)
    }

    fileprivate func makeBGRATexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var texRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &texRef
        )
        guard status == kCVReturnSuccess, let texRef, let tex = CVMetalTextureGetTexture(texRef) else { return nil }

        return tex
    }
}

extension CameraMetalPreviewModel.PersistedState: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.overlayMode == rhs.overlayMode &&
        lhs.zebraThreshold == rhs.zebraThreshold &&
        lhs.brightness == rhs.brightness &&
        lhs.contrast == rhs.contrast &&
        lhs.saturation == rhs.saturation &&
        lhs.lutEnabled == rhs.lutEnabled &&
        lhs.lutName == rhs.lutName
        // MTLTexture identity is proxied through lutName — same name implies same texture load
    }
}

private struct CameraMetalPreviewView: NSViewRepresentable {
    let model: CameraMetalPreviewModel

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = model.device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Nothing — rendering is continuous.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let model: CameraMetalPreviewModel

        private var quadBuffer: MTLBuffer?
        private var offscreenPool: CVPixelBufferPool?
        private var offscreenPoolAttributes: [String: Any]?

        init(model: CameraMetalPreviewModel) {
            self.model = model
            super.init()

            guard let device = model.device else { return }

            // position.xy, texcoord.xy
            let verts: [Float] = [
                -1, -1,  0, 1,
                 1, -1,  1, 1,
                -1,  1,  0, 0,
                 1,  1,  1, 0
            ]
            quadBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.stride, options: .storageModeShared)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let queue = model.commandQueue,
                  let quadBuffer else {
                return
            }

            // Grab the latest frame (may be nil until camera is running)
            guard let pb = model.takeLatestPixelBuffer() else {
                // Clear only
                let cmd = queue.makeCommandBuffer()
                if let cmd {
                    cmd.label = "CameraMetalPreview.ClearOnly.NoFrame"
                    MetalGPUStatsCollector.shared.record(commandBuffer: cmd)
                }
                if let enc = cmd?.makeRenderCommandEncoder(descriptor: rpd) {
                    enc.endEncoding()
                }
                cmd?.present(drawable)
                cmd?.commit()
                return
            }

            // Detect pixel buffer format
            let format = CVPixelBufferGetPixelFormatType(pb)
            let isBGRA = (format == kCVPixelFormatType_32BGRA)

            // Select appropriate pipeline (LUT variant if enabled + texture loaded)
            let useLUT = model.lutEnabled && model.lutTexture != nil
            let pso: MTLRenderPipelineState?
            if isBGRA {
                pso = useLUT ? (model.pipelineStateBGRALUT ?? model.pipelineStateBGRA) : model.pipelineStateBGRA
            } else {
                pso = useLUT ? (model.pipelineStateNV12LUT ?? model.pipelineStateNV12) : model.pipelineStateNV12
            }

            guard let pso else {
                // No pipeline available, clear
                let cmd = queue.makeCommandBuffer()
                if let cmd {
                    cmd.label = "CameraMetalPreview.ClearOnly.NoPipeline"
                    MetalGPUStatsCollector.shared.record(commandBuffer: cmd)
                }
                if let enc = cmd?.makeRenderCommandEncoder(descriptor: rpd) {
                    enc.endEncoding()
                }
                cmd?.present(drawable)
                cmd?.commit()
                return
            }

            if let cache = model.textureCache {
                CVMetalTextureCacheFlush(cache, 0)
            }

            let focusOverlaySource: AnyObject?
            if #available(macOS 14.0, *),
               let focusEngine = model.focusPeakingEngine as? FocusPeakingEngine,
               focusEngine.isEnabled {
                focusOverlaySource = focusEngine
            } else {
                focusOverlaySource = nil
            }

            renderNormalVideo(drawable: drawable, rpd: rpd, queue: queue, pso: pso, quadBuffer: quadBuffer, pb: pb, isBGRA: isBGRA, focusEngine: focusOverlaySource)

            // If recording processed frames, render to offscreen buffer as well
            if let onProcessedFrame = model.onProcessedFrame {
                if let processedBuffer = createProcessedBuffer(from: pb) {
                    renderToBuffer(processedBuffer, queue: queue, pso: pso, quadBuffer: quadBuffer, sourceBuffer: pb, isBGRA: isBGRA)
                    onProcessedFrame(processedBuffer, model.lastProcessedTimestamp)
                }
            }
        }

        private func createProcessedBuffer(from source: CVPixelBuffer) -> CVPixelBuffer? {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)

            if offscreenPool == nil || offscreenPoolAttributes?["Width"] as? Int != width || offscreenPoolAttributes?["Height"] as? Int != height {
                let poolAttrs = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
                let pbAttrs: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                offscreenPoolAttributes = ["Width": width, "Height": height]
                CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, pbAttrs as CFDictionary, &offscreenPool)
            }

            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, offscreenPool!, &pb)
            return pb
        }

        private func renderToBuffer(_ dest: CVPixelBuffer, queue: MTLCommandQueue, pso: MTLRenderPipelineState, quadBuffer: MTLBuffer, sourceBuffer: CVPixelBuffer, isBGRA: Bool) {
            guard let cache = model.textureCache else { return }

            var destTexRef: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                dest,
                nil,
                .bgra8Unorm,
                CVPixelBufferGetWidth(dest),
                CVPixelBufferGetHeight(dest),
                0,
                &destTexRef
            )

            guard let destTexRef, let destTex = CVMetalTextureGetTexture(destTexRef) else { return }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = destTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

            renderNormalVideoInternal(rpd: rpd, queue: queue, pso: pso, quadBuffer: quadBuffer, pb: sourceBuffer, isBGRA: isBGRA)
        }

        private func renderNormalVideo(drawable: CAMetalDrawable, rpd: MTLRenderPassDescriptor, queue: MTLCommandQueue, pso: MTLRenderPipelineState, quadBuffer: MTLBuffer, pb: CVPixelBuffer, isBGRA: Bool, focusEngine: AnyObject? = nil) {
            renderNormalVideoInternal(rpd: rpd, queue: queue, pso: pso, quadBuffer: quadBuffer, pb: pb, isBGRA: isBGRA, focusEngine: focusEngine)

            // Only the display pass needs to present
            if let cmd = queue.makeCommandBuffer() {
                cmd.present(drawable)
                cmd.commit()
            }
        }

        private func renderNormalVideoInternal(rpd: MTLRenderPassDescriptor, queue: MTLCommandQueue, pso: MTLRenderPipelineState, quadBuffer: MTLBuffer, pb: CVPixelBuffer, isBGRA: Bool, focusEngine: AnyObject? = nil) {
            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
                return
            }
            cmd.label = "CameraMetalPreview.RenderInternal"

            enc.setRenderPipelineState(pso)
            enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)

            let useLUT = model.lutEnabled && model.lutTexture != nil

            if isBGRA {
                guard let bgraTex = model.makeBGRATexture(from: pb) else {
                    enc.endEncoding()
                    return
                }
                enc.setFragmentTexture(bgraTex, index: 0)
                if useLUT, let lut = model.lutTexture {
                    enc.setFragmentTexture(lut, index: 1)
                }
            } else {
                guard let (yTex, uvTex) = model.makeNV12Textures(from: pb) else {
                    enc.endEncoding()
                    return
                }
                enc.setFragmentTexture(yTex, index: 0)
                enc.setFragmentTexture(uvTex, index: 1)
                if useLUT, let lut = model.lutTexture {
                    enc.setFragmentTexture(lut, index: 2)
                }
            }

            if let s = model.sampler {
                enc.setFragmentSamplerState(s, index: 0)
            }

            var uniforms = PreviewUniforms(
                brightness: model.brightness,
                contrast: model.contrast,
                saturation: model.saturation,
                overlayMode: model.overlayMode.rawValue,
                zebraThreshold: model.zebraThreshold
            )
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)

            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()

            if #available(macOS 14.0, *), let focusEngine = focusEngine as? FocusPeakingEngine {
                do {
                    let edgeMask = try focusEngine.prepareEdgeMask(pb, using: cmd)
                    let overlayRPD = MTLRenderPassDescriptor()
                    overlayRPD.colorAttachments[0].texture = rpd.colorAttachments[0].texture
                    overlayRPD.colorAttachments[0].loadAction = .load
                    overlayRPD.colorAttachments[0].storeAction = .store

                    if let overlayEncoder = cmd.makeRenderCommandEncoder(descriptor: overlayRPD) {
                        overlayEncoder.setRenderPipelineState(focusEngine.overlayRenderPipelineState)
                        overlayEncoder.setFragmentTexture(edgeMask, index: 0)

                        var color = focusEngine.overlayColor
                        overlayEncoder.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)

                        var opacity = focusEngine.overlayOpacity
                        overlayEncoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 1)

                        overlayEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        overlayEncoder.endEncoding()
                    }
                } catch {
                    print("Focus peaking error: \(error)")
                }
            }

            cmd.commit()
        }
    }
}

// MARK: - Scopes (Vectorscope + Parade)

final class VideoScopesModel: NSObject {

    enum Kind { case vectorscope, parade, waveform }

    private let device: MTLDevice?

    /// Expose the Metal device so MTKView can be configured without KVC.
    var metalDevice: MTLDevice? { device }
    private let queue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?

    // Compute
    private var clearPSO: MTLComputePipelineState?
    private var vecAccPSONV12: MTLComputePipelineState?
    private var vecAccPSOBGRA: MTLComputePipelineState?
    private var vecRenderPSO: MTLComputePipelineState?
    private var parAccPSONV12: MTLComputePipelineState?
    private var parAccPSOBGRA: MTLComputePipelineState?
    private var parRenderPSO: MTLComputePipelineState?
    private var ringPSO: MTLComputePipelineState?
    private var waveformParadeGraticulePSO: MTLComputePipelineState?
    private var vectorscopeGraticulePSO: MTLComputePipelineState?
    private var lumaAccPSONV12: MTLComputePipelineState?
    private var lumaAccPSOBGRA: MTLComputePipelineState?
    private var lumaRenderPSO: MTLComputePipelineState?

    // Display
    private var displayPSO: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var quadBuffer: MTLBuffer?

    // Output textures
    private var vectorscopeTex: MTLTexture?
    private var paradeTex: MTLTexture?

    // Static overlay for vectorscope (hue ring)
    private var vectorscopeRingTex: MTLTexture?
    private var vectorscopeGraticuleTex: MTLTexture?

    // Output textures and hist buffers
    private var waveformTex: MTLTexture?
    private var waveformGraticuleTex: MTLTexture?
    private var paradeGraticuleTex: MTLTexture?
    private var waveformHist: MTLBuffer?
    // Hist buffers
    private var vectorscopeHist: MTLBuffer?
    private var paradeHist: MTLBuffer?

    // Latest frame
    private let frameQueue = DispatchQueue(label: "VideoScopesModel.frameQueue")
    private var latestPixelBuffer: CVPixelBuffer?

    // Sizes
    private let vectorscopeSize = MTLSize(width: 288, height: 288, depth: 1)
    private let paradeSize      = MTLSize(width: 288, height: 288, depth: 1) // 3 lanes
    private let waveformSize    = MTLSize(width: 288, height: 288, depth: 1) // spatial luma

    init(device: MTLDevice?) {
        self.device = device
        self.queue = device?.makeCommandQueue()
        super.init()

        guard let device else { return }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sd)

        // Full-screen quad (float4 per-vertex: pos.xy, uv.xy)
        let verts: [SIMD4<Float>] = [
            SIMD4(-1, -1,  0, 1),
            SIMD4( 1, -1,  1, 1),
            SIMD4(-1,  1,  0, 0),
            SIMD4( 1,  1,  1, 0)
        ]
        self.quadBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)

        buildPipelines(device: device)
        allocateOutputs(device: device)
    }

    func enqueue(pixelBuffer: CVPixelBuffer) {
        frameQueue.async {
            self.latestPixelBuffer = pixelBuffer
        }
    }

    private func takeLatest() -> CVPixelBuffer? {
        frameQueue.sync { latestPixelBuffer }
    }

    private func buildPipelines(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared

        func makeCompute(_ name: String) -> MTLComputePipelineState? {
            return compilerCache.computePipelineState(functionName: name)
        }

        clearPSO = makeCompute("clearU32Histogram")
        vecAccPSONV12 = makeCompute("accumulateVectorscopeNV12")
        vecAccPSOBGRA = makeCompute("accumulateVectorscopeBGRA")
        vecRenderPSO = makeCompute("renderVectorscope")
        parAccPSONV12 = makeCompute("accumulateParadeNV12")
        parAccPSOBGRA = makeCompute("accumulateParadeBGRA")
        parRenderPSO = makeCompute("renderParade")
        ringPSO        = makeCompute("renderVectorscopeHueRing")
        waveformParadeGraticulePSO = makeCompute("renderWaveformParadeGraticule")
        vectorscopeGraticulePSO = makeCompute("renderVectorscopeGraticule")
        lumaAccPSONV12 = makeCompute("accumulateLumaWaveformNV12")
        lumaAccPSOBGRA = makeCompute("accumulateLumaWaveformBGRA")
        lumaRenderPSO  = makeCompute("renderLumaWaveform")

        // Display pipeline (samples an RGBA texture)
        displayPSO = compilerCache.pipelineState(
            vertexFunctionName: "nv12QuadVertex",
            fragmentFunctionName: "texQuadFragment",
            pixelFormat: .bgra8Unorm,
            blendingMode: .alphaBlend
        )
    }

    private func allocateOutputs(device: MTLDevice) {
        // Output textures
        let vecDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: vectorscopeSize.width, height: vectorscopeSize.height, mipmapped: false)
        vecDesc.usage = [.shaderWrite, .shaderRead]
        vectorscopeTex = device.makeTexture(descriptor: vecDesc)

        // Hue ring overlay (static, generated once)
        let ringDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: vectorscopeSize.width,
            height: vectorscopeSize.height,
            mipmapped: false
        )
        ringDesc.usage = [.shaderWrite, .shaderRead]
        vectorscopeRingTex = device.makeTexture(descriptor: ringDesc)
        vectorscopeGraticuleTex = device.makeTexture(descriptor: ringDesc)

        let parDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: paradeSize.width, height: paradeSize.height, mipmapped: false)
        parDesc.usage = [.shaderWrite, .shaderRead]
        paradeTex = device.makeTexture(descriptor: parDesc)
        paradeGraticuleTex = device.makeTexture(descriptor: parDesc)

        // Hist buffers (atomic_uint per bin)
        let vecBins = vectorscopeSize.width * vectorscopeSize.height
        vectorscopeHist = device.makeBuffer(length: vecBins * MemoryLayout<UInt32>.stride, options: .storageModeShared)

        let parBins = paradeSize.width * paradeSize.height
        paradeHist = device.makeBuffer(length: parBins * MemoryLayout<UInt32>.stride, options: .storageModeShared)

        let waveDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: waveformSize.width, height: waveformSize.height, mipmapped: false)
        waveDesc.usage = [.shaderWrite, .shaderRead]
        waveformTex = device.makeTexture(descriptor: waveDesc)
        waveformGraticuleTex = device.makeTexture(descriptor: waveDesc)

        let waveBins = waveformSize.width * waveformSize.height
        waveformHist = device.makeBuffer(length: waveBins * MemoryLayout<UInt32>.stride, options: .storageModeShared)

        buildVectorscopeRingIfNeeded()
        buildScopeGraticulesIfNeeded()
    }

    private func buildVectorscopeRingIfNeeded() {
        guard let queue,
              let ringPSO,
              let ringTex = vectorscopeRingTex else { return }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        enc.setComputePipelineState(ringPSO)
        enc.setTexture(ringTex, index: 0)

        // Normalized radii in scope space (0..1). Tweak to taste.
        var innerR: Float = 0.78
        var outerR: Float = 0.92
        var alpha: Float = 0.85

        enc.setBytes(&innerR, length: MemoryLayout<Float>.stride, index: 0)
        enc.setBytes(&outerR, length: MemoryLayout<Float>.stride, index: 1)
        enc.setBytes(&alpha, length: MemoryLayout<Float>.stride, index: 2)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: ringTex.width, height: ringTex.height, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()

        cmd.commit()
    }

    private func buildScopeGraticulesIfNeeded() {
        guard let queue,
              let waveformParadeGraticulePSO,
              let vectorscopeGraticulePSO,
              let waveformGraticuleTex,
              let paradeGraticuleTex,
              let vectorscopeGraticuleTex else { return }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return }

        let tg = MTLSize(width: 16, height: 16, depth: 1)

        enc.setComputePipelineState(waveformParadeGraticulePSO)
        enc.setTexture(waveformGraticuleTex, index: 0)
        var waveformOverlaySize = SIMD2<UInt32>(UInt32(waveformGraticuleTex.width), UInt32(waveformGraticuleTex.height))
        var waveformMode: UInt32 = 0
        enc.setBytes(&waveformOverlaySize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
        enc.setBytes(&waveformMode, length: MemoryLayout<UInt32>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: waveformGraticuleTex.width, height: waveformGraticuleTex.height, depth: 1), threadsPerThreadgroup: tg)

        enc.setTexture(paradeGraticuleTex, index: 0)
        var paradeOverlaySize = SIMD2<UInt32>(UInt32(paradeGraticuleTex.width), UInt32(paradeGraticuleTex.height))
        var paradeMode: UInt32 = 1
        enc.setBytes(&paradeOverlaySize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
        enc.setBytes(&paradeMode, length: MemoryLayout<UInt32>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: paradeGraticuleTex.width, height: paradeGraticuleTex.height, depth: 1), threadsPerThreadgroup: tg)

        enc.setComputePipelineState(vectorscopeGraticulePSO)
        enc.setTexture(vectorscopeGraticuleTex, index: 0)
        enc.dispatchThreads(MTLSize(width: vectorscopeGraticuleTex.width, height: vectorscopeGraticuleTex.height, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()

        cmd.commit()
    }

    private func makeNV12Textures(from pixelBuffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var yRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm, width, height, 0, &yRef)
        guard yStatus == kCVReturnSuccess, let yRef, let yTex = CVMetalTextureGetTexture(yRef) else { return nil }

        var uvRef: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm, width/2, height/2, 1, &uvRef)
        guard uvStatus == kCVReturnSuccess, let uvRef, let uvTex = CVMetalTextureGetTexture(uvRef) else { return nil }

        return (yTex, uvTex)
    }

    private func makeBGRATexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var texRef: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &texRef
        )
        guard status == kCVReturnSuccess, let texRef, let tex = CVMetalTextureGetTexture(texRef) else { return nil }

        return tex
    }

    func draw(kind: Kind, in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let queue,
              let displayPSO,
              let quadBuffer,
              let samp = sampler else { return }

        guard let pb = takeLatest() else {
            let cmd = queue.makeCommandBuffer()
            if let enc = cmd?.makeRenderCommandEncoder(descriptor: rpd) { enc.endEncoding() }
            cmd?.present(drawable)
            cmd?.commit()
            return
        }

        // Detect pixel buffer format
        let format = CVPixelBufferGetPixelFormatType(pb)
        let isBGRA = (format == kCVPixelFormatType_32BGRA)

        // Flush cache occasionally
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }

        guard let cmd = queue.makeCommandBuffer() else { return }

        // Compute: build the chosen scope texture
        if let cenc = cmd.makeComputeCommandEncoder() {
            switch kind {
            case .vectorscope:
                guard let clearPSO, let vecRenderPSO, let hist = vectorscopeHist, let outTex = vectorscopeTex else { break }

                let vecAccPSO = isBGRA ? vecAccPSOBGRA : vecAccPSONV12
                guard let vecAccPSO else { break }

                // Clear histogram
                cenc.setComputePipelineState(clearPSO)
                cenc.setBuffer(hist, offset: 0, index: 0)
                var count: UInt32 = UInt32(vectorscopeSize.width * vectorscopeSize.height)
                cenc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
                let tg = MTLSize(width: 256, height: 1, depth: 1)
                let grid = MTLSize(width: Int(count), height: 1, depth: 1)
                cenc.dispatchThreads(grid, threadsPerThreadgroup: tg)

                // Accumulate
                cenc.setComputePipelineState(vecAccPSO)

                if isBGRA {
                    // BGRA path: single texture
                    guard let bgraTex = makeBGRATexture(from: pb) else { break }
                    cenc.setTexture(bgraTex, index: 0)
                } else {
                    // NV12 path: Y + UV textures
                    guard let (yTex, uvTex) = makeNV12Textures(from: pb) else { break }
                    cenc.setTexture(yTex, index: 0)
                    cenc.setTexture(uvTex, index: 1)
                }

                cenc.setSamplerState(samp, index: 0)
                cenc.setBuffer(hist, offset: 0, index: 0)
                var scopeSize = SIMD2<UInt32>(UInt32(vectorscopeSize.width), UInt32(vectorscopeSize.height))
                cenc.setBytes(&scopeSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                var inputSize = SIMD2<UInt32>(UInt32(CVPixelBufferGetWidth(pb)), UInt32(CVPixelBufferGetHeight(pb)))
                cenc.setBytes(&inputSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
                var step: UInt32 = 2
                cenc.setBytes(&step, length: MemoryLayout<UInt32>.stride, index: 3)

                let grid2 = MTLSize(width: Int(inputSize.x), height: Int(inputSize.y), depth: 1)
                let tg2 = MTLSize(width: 16, height: 16, depth: 1)
                cenc.dispatchThreads(grid2, threadsPerThreadgroup: tg2)

                // Render to texture
                cenc.setComputePipelineState(vecRenderPSO)
                cenc.setBuffer(hist, offset: 0, index: 0)
                cenc.setTexture(outTex, index: 0)
                cenc.setBytes(&scopeSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                var decay: Float = 0.92
                cenc.setBytes(&decay, length: MemoryLayout<Float>.stride, index: 2)
                let grid3 = MTLSize(width: vectorscopeSize.width, height: vectorscopeSize.height, depth: 1)
                cenc.dispatchThreads(grid3, threadsPerThreadgroup: tg2)

            case .parade:
                guard let clearPSO, let parRenderPSO, let hist = paradeHist, let outTex = paradeTex else { break }

                let parAccPSO = isBGRA ? parAccPSOBGRA : parAccPSONV12
                guard let parAccPSO else { break }

                // Clear histogram
                cenc.setComputePipelineState(clearPSO)
                cenc.setBuffer(hist, offset: 0, index: 0)
                var count: UInt32 = UInt32(paradeSize.width * paradeSize.height)
                cenc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
                let tg = MTLSize(width: 256, height: 1, depth: 1)
                let grid = MTLSize(width: Int(count), height: 1, depth: 1)
                cenc.dispatchThreads(grid, threadsPerThreadgroup: tg)

                // Accumulate
                cenc.setComputePipelineState(parAccPSO)

                if isBGRA {
                    // BGRA path: single texture
                    guard let bgraTex = makeBGRATexture(from: pb) else { break }
                    cenc.setTexture(bgraTex, index: 0)
                } else {
                    // NV12 path: Y + UV textures
                    guard let (yTex, uvTex) = makeNV12Textures(from: pb) else { break }
                    cenc.setTexture(yTex, index: 0)
                    cenc.setTexture(uvTex, index: 1)
                }

                cenc.setSamplerState(samp, index: 0)
                cenc.setBuffer(hist, offset: 0, index: 0)
                var pSize = SIMD2<UInt32>(UInt32(paradeSize.width), UInt32(paradeSize.height))
                cenc.setBytes(&pSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                var inputSize = SIMD2<UInt32>(UInt32(CVPixelBufferGetWidth(pb)), UInt32(CVPixelBufferGetHeight(pb)))
                cenc.setBytes(&inputSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
                var step: UInt32 = 2
                cenc.setBytes(&step, length: MemoryLayout<UInt32>.stride, index: 3)

                let grid2 = MTLSize(width: Int(inputSize.x), height: Int(inputSize.y), depth: 1)
                let tg2 = MTLSize(width: 16, height: 16, depth: 1)
                cenc.dispatchThreads(grid2, threadsPerThreadgroup: tg2)

                // Render to texture
                cenc.setComputePipelineState(parRenderPSO)
                cenc.setBuffer(hist, offset: 0, index: 0)
                cenc.setTexture(outTex, index: 0)
                cenc.setBytes(&pSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                var decay: Float = 0.90
                cenc.setBytes(&decay, length: MemoryLayout<Float>.stride, index: 2)
                let grid3 = MTLSize(width: paradeSize.width, height: paradeSize.height, depth: 1)
                cenc.dispatchThreads(grid3, threadsPerThreadgroup: tg2)

            case .waveform:
                guard let clearPSO, let lumaRenderPSO,
                      let hist = waveformHist, let outTex = waveformTex else { break }

                let lumaAccPSO = isBGRA ? lumaAccPSOBGRA : lumaAccPSONV12
                guard let lumaAccPSO else { break }

                // Clear histogram
                cenc.setComputePipelineState(clearPSO)
                cenc.setBuffer(hist, offset: 0, index: 0)
                var count: UInt32 = UInt32(waveformSize.width * waveformSize.height)
                cenc.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
                cenc.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

                // Accumulate
                cenc.setComputePipelineState(lumaAccPSO)
                if isBGRA {
                    guard let bgraTex = makeBGRATexture(from: pb) else { break }
                    cenc.setTexture(bgraTex, index: 0)
                } else {
                    guard let (yTex, uvTex) = makeNV12Textures(from: pb) else { break }
                    cenc.setTexture(yTex, index: 0)
                    cenc.setTexture(uvTex, index: 1)
                }
                cenc.setSamplerState(samp, index: 0)
                cenc.setBuffer(hist, offset: 0, index: 0)
                var wSize = SIMD2<UInt32>(UInt32(waveformSize.width), UInt32(waveformSize.height))
                cenc.setBytes(&wSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                var inputSize = SIMD2<UInt32>(UInt32(CVPixelBufferGetWidth(pb)), UInt32(CVPixelBufferGetHeight(pb)))
                cenc.setBytes(&inputSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
                var step: UInt32 = 2
                cenc.setBytes(&step, length: MemoryLayout<UInt32>.stride, index: 3)
                cenc.dispatchThreads(MTLSize(width: Int(inputSize.x), height: Int(inputSize.y), depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))

                // Render to texture
                cenc.setComputePipelineState(lumaRenderPSO)
                cenc.setBuffer(hist, offset: 0, index: 0)
                cenc.setTexture(outTex, index: 0)
                cenc.setBytes(&wSize, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                var decay: Float = 0.92
                cenc.setBytes(&decay, length: MemoryLayout<Float>.stride, index: 2)
                cenc.dispatchThreads(MTLSize(width: waveformSize.width, height: waveformSize.height, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }

            cenc.endEncoding()
        }

        // Render: draw scope texture(s) to the MTKView drawable
        if let renc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            renc.setRenderPipelineState(displayPSO)
            renc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            renc.setFragmentSamplerState(samp, index: 0)

            switch kind {
            case .vectorscope:
                if let graticule = vectorscopeGraticuleTex {
                    renc.setFragmentTexture(graticule, index: 0)
                    renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                if let tex = vectorscopeTex {
                    renc.setFragmentTexture(tex, index: 0)
                    renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                if let ring = vectorscopeRingTex {
                    renc.setFragmentTexture(ring, index: 0)
                    renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }

            case .parade:
                if let graticule = paradeGraticuleTex {
                    renc.setFragmentTexture(graticule, index: 0)
                    renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                if let tex = paradeTex {
                    renc.setFragmentTexture(tex, index: 0)
                    renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }

            case .waveform:
                if let graticule = waveformGraticuleTex {
                    renc.setFragmentTexture(graticule, index: 0)
                    renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                if let tex = waveformTex {
                    renc.setFragmentTexture(tex, index: 0)
                    renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }

            renc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }
}

private struct VideoScopeMTKView: NSViewRepresentable {
    let model: VideoScopesModel
    let kind: VideoScopesModel.Kind

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = model.metalDevice
        if v.device == nil {
            // Metal not available; leave view blank and don't attach a delegate.
            v.clearColor = MTLClearColorMake(0, 0, 0, 1)
            return v
        }
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.preferredFramesPerSecond = 30
        v.clearColor = MTLClearColorMake(0, 0, 0, 0)   // transparent background
        // Make the CAMetalLayer itself composit over the SwiftUI background
        v.wantsLayer = true
        v.layer?.isOpaque = false
        v.layer?.backgroundColor = .clear
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, kind: kind)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let model: VideoScopesModel
        private let kind: VideoScopesModel.Kind

        init(model: VideoScopesModel, kind: VideoScopesModel.Kind) {
            self.model = model
            self.kind = kind
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            model.draw(kind: kind, in: view)
        }
    }
}

// MARK: - Overlay Controls

private struct OverlayControlsView: View {
    @ObservedObject var model: CameraMetalPreviewModel
    @Environment(\.appUIScale) private var appUIScale
    private var scaledFontSize: CGFloat { 13 * appUIScale }
    private var scaledSmallFont: CGFloat { 11 * appUIScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "square.on.square.dashed")
                    .foregroundColor(.secondary)
                Text("Overlays")
                    .font(.system(size: scaledFontSize, weight: .semibold))
            }

            // Mode picker
            HStack(spacing: 6) {
                ForEach(CameraMetalPreviewModel.PreviewOverlay.allCases, id: \.rawValue) { mode in
                    Button {
                        model.overlayMode = mode
                    } label: {
                        Label(mode.label, systemImage: mode.icon)
                            .font(.system(size: scaledSmallFont))
                    }
                    .buttonStyle(.bordered)
                    .overlay(
                        ThemeRoundedRectangle(cornerRadius: 6)
                            .stroke(model.overlayMode == mode ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .help(modeHelp(mode))
                }
            }

            // Zebra threshold (only when zebra is active)
            if model.overlayMode == .zebra {
                HStack(spacing: 8) {
                    Text("Threshold")
                        .font(.system(size: scaledSmallFont))
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Slider(value: $model.zebraThreshold, in: 0.7...1.0)
                    Text("\(Int(model.zebraThreshold * 100))%")
                        .font(.system(size: scaledSmallFont, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.05))
                .overlay(ThemeRoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
    }

    private func modeHelp(_ mode: CameraMetalPreviewModel.PreviewOverlay) -> String {
        switch mode {
        case .none:          return "Normal preview"
        case .framingGuides: return "Rule of thirds, centre cross, 90% safe zone"
        case .zebra:         return "Amber stripes on pixels above the luma threshold"
        case .falseColor:    return "ARRI-inspired exposure map: green = correct, red = clipping"
        }
    }
}

// MARK: - Image Adjustments

private struct ImageAdjustmentsView: View {
    @ObservedObject var model: CameraMetalPreviewModel
    @Environment(\.appUIScale) private var appUIScale
    private var scaledFontSize: CGFloat { 13 * appUIScale }
    private var scaledSmallFont: CGFloat { 11 * appUIScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.secondary)
                Text("Image Adjustments")
                    .font(.system(size: scaledFontSize, weight: .semibold))

                Spacer()

                // Reset all to identity
                if model.brightness != 0 || model.contrast != 1 || model.saturation != 1 {
                    Button("Reset") {
                        model.brightness = 0
                        model.contrast   = 1
                        model.saturation = 1
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: scaledSmallFont))
                    .foregroundColor(.secondary)
                }
            }

            adjustRow("Brightness", value: $model.brightness,
                      in: -0.5...0.5, format: "%+.2f", identity: 0)
            adjustRow("Contrast",   value: $model.contrast,
                      in: 0...2,     format: "%.2f",  identity: 1)
            adjustRow("Saturation", value: $model.saturation,
                      in: 0...2,     format: "%.2f",  identity: 1)
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.05))
                .overlay(ThemeRoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
    }

    @ViewBuilder
    private func adjustRow(_ label: String, value: Binding<Float>,
                            in range: ClosedRange<Float>, format: String, identity: Float) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: scaledSmallFont))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: scaledSmallFont, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
            Button {
                value.wrappedValue = identity
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Reset to default")
        }
    }
}

// MARK: - LUT Controls

private struct LUTControlsView: View {
    @ObservedObject var model: CameraMetalPreviewModel
    @State private var showingFilePicker = false
    @Environment(\.appUIScale) private var appUIScale

    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "cube")
                    .foregroundColor(.secondary)
                Text("Color LUT")
                    .font(.system(size: scaledHeadlineFontSize, weight: .semibold))

                Spacer()

                if model.lutName != nil {
                    Toggle("", isOn: $model.lutEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("Enable or disable the loaded LUT")
                }
            }

            HStack(spacing: 8) {
                Button {
                    showingFilePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.badge.plus")
                        Text(model.lutName ?? "Load .cube LUT")
                            .font(.system(size: scaledCaptionFontSize))
                    }
                }
                .buttonStyle(.bordered)
                .help("Load a .cube 3D LUT file (Adobe / DaVinci Resolve format)")

                if model.lutName != nil {
                    Button {
                        model.removeLUT()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove loaded LUT")
                }
            }
        }
        .padding(12)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                model.loadLUT(from: url)
            }
        }
    }
}

// MARK: - Exposure Analysis Card

private struct ExposureAnalysisCard: View {
    @Binding var isAnalyzing: Bool
    @Binding var result: ExposureAnalyzer.Result?
    let onAnalyze: () -> Void
    @Environment(\.appUIScale) private var appUIScale
    private var scaledFontSize: CGFloat { 13 * appUIScale }
    private var scaledSmallFont: CGFloat { 11 * appUIScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sun.max")
                    .foregroundColor(.secondary)
                Text("Exposure Analysis")
                    .font(.system(size: scaledFontSize, weight: .semibold))
                Spacer()
                if let result {
                    ratingBadge(result)
                }
            }

            Button(action: onAnalyze) {
                HStack {
                    Image(systemName: isAnalyzing ? "hourglass" : "camera.aperture")
                    Text(isAnalyzing ? "Analyzing..." : "Analyze Exposure")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isAnalyzing)
            .help("Analyze current frame for exposure — uses face detection to target the subject")

            if let result {
                Divider()

                // Stats row
                HStack(spacing: 16) {
                    statItem(label: "Mean Luma", value: String(format: "%.1f%%", result.meanLuma * 100))
                    statItem(label: "Highlights", value: String(format: "%.1f%%", result.highlightPercent),
                             warn: result.highlightPercent > 2)
                    statItem(label: "Shadows", value: String(format: "%.1f%%", result.shadowPercent))
                    if let faceLuma = result.faceMeanLuma {
                        statItem(label: "Face Luma", value: String(format: "%.1f%%", faceLuma * 100))
                    }
                    Spacer()
                    if !result.faceBoxes.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("\(result.faceBoxes.count) face\(result.faceBoxes.count == 1 ? "" : "s")")
                                .font(.system(size: scaledSmallFont))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Mini histogram
                exposureCapsule(result)
                    .frame(height: 54)

                // Tip
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 1)
                    Text(result.tip)
                        .font(.system(size: scaledSmallFont))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.05), stroke: Color.white.opacity(0.1))
        )
    }

    @ViewBuilder
    private func ratingBadge(_ result: ExposureAnalyzer.Result) -> some View {
        let c = result.ratingColor
        Text(result.rating.rawValue)
            .font(.system(size: scaledSmallFont, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                ThemeRoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: c.r, green: c.g, blue: c.b))
            )
    }

    @ViewBuilder
    private func statItem(label: String, value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: scaledSmallFont, weight: .semibold, design: .monospaced))
                .foregroundColor(warn ? .orange : .primary)
        }
    }

    private func exposureCapsule(_ result: ExposureAnalyzer.Result) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let clippedMean = min(max(CGFloat(result.meanLuma), 0), 1)
            let meanOffset = clippedMean * width
            let faceOffset = result.faceMeanLuma.map { min(max(CGFloat($0), 0), 1) * width }
            let shadowFraction = min(max(CGFloat(result.shadowPercent / 100), 0), 1)
            let highlightFraction = min(max(CGFloat(result.highlightPercent / 100), 0), 1)
            let shadowMarkerWidth = result.shadowPercent > 0 ? max(width * shadowFraction, 3) : 0
            let highlightMarkerWidth = result.highlightPercent > 0 ? max(width * highlightFraction, 3) : 0

            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black,
                                    Color(white: 0.35, opacity: 1.0),
                                    Color.white
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Capsule()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                        .frame(maxWidth: .infinity, alignment: .center)
                    if shadowMarkerWidth > 0 {
                        Capsule()
                            .fill(Color(red: 0.38, green: 0.00, blue: 0.55).opacity(0.86))
                            .frame(width: shadowMarkerWidth)
                            .padding(.vertical, 4)
                    }
                    if highlightMarkerWidth > 0 {
                        Capsule()
                            .fill(Color(red: 1.00, green: 0.20, blue: 0.00).opacity(0.90))
                            .frame(width: highlightMarkerWidth)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Circle()
                        .fill(Color(red: 0.07, green: 0.12, blue: 0.20))
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .offset(x: min(max(meanOffset - 7, 0), max(width - 14, 0)))
                    if let faceOffset {
                        Circle()
                            .fill(Color(red: 0.05, green: 0.65, blue: 0.10))
                            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                            .frame(width: 10, height: 10)
                            .offset(x: min(max(faceOffset - 5, 0), max(width - 10, 0)))
                    }
                }
                .frame(height: 22)

                HStack(spacing: 8) {
                    Text("Black")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Gray")
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text("White")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func miniHistogram(_ hist: [Float]) -> some View {
        if #available(macOS 12.0, *) {
            Canvas { ctx, size in
                let buckets = hist.count
                guard buckets > 0 else { return }
                let peak = hist.max() ?? 1
                guard peak > 0 else { return }
                let barW = size.width / CGFloat(buckets)
                for i in 0..<buckets {
                    let h = CGFloat(hist[i] / peak) * size.height
                    let x = CGFloat(i) * barW
                    let rect = CGRect(x: x, y: size.height - h, width: max(barW - 0.5, 0.5), height: h)
                    let t = Float(i) / Float(buckets - 1)
                    let barColor: Color
                    if t < 0.05 { barColor = Color(red: 0.38, green: 0.00, blue: 0.55) }
                    else if t < 0.40 { barColor = Color(red: 0.05, green: 0.10, blue: 0.70) }
                    else if t < 0.65 { barColor = Color(red: 0.05, green: 0.65, blue: 0.10) }
                    else if t < 0.85 { barColor = Color(red: 1.00, green: 0.75, blue: 0.00) }
                    else             { barColor = Color(red: 1.00, green: 0.20, blue: 0.00) }
                    ctx.fill(Path(rect), with: .color(barColor.opacity(0.8)))
                }
            }
        } else {
            // macOS 11 fallback: exposure zone gradient
            LinearGradient(
                colors: [
                    Color(red: 0.38, green: 0.00, blue: 0.55).opacity(0.5),
                    Color(red: 0.05, green: 0.10, blue: 0.70).opacity(0.5),
                    Color(red: 0.05, green: 0.65, blue: 0.10).opacity(0.5),
                    Color(red: 1.00, green: 0.75, blue: 0.00).opacity(0.5),
                    Color(red: 1.00, green: 0.20, blue: 0.00).opacity(0.5)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}

// MARK: - Card

private struct Card<Content: View>: View {
    @Environment(\.appUIScale) private var appUIScale
    @ViewBuilder var content: Content

    private var scaledCornerRadius: CGFloat { 16 }
    private var scaledPadding: CGFloat { 12 }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
            .fill(Color.black.opacity(0.05))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .overlay(content.padding(scaledPadding))
    }
}

// MARK: - Native Preview Layer View

/// Uses AVCaptureVideoPreviewLayer as the view's backing layer for maximum
/// compatibility on Big Sur/Monterey Intel Macs.  The preview layer is created
/// with the session upfront (some Big Sur builds ignore later `.session =` assignment)
/// and is used as the view's own layer via `makeBackingLayer()` — the most reliable
/// compositing path on older Intel GPU drivers that can fail to display sublayers
/// added after `wantsLayer = true` + layer replacement.
private struct NativePreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView(session: session)
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        // Re-assign in case SwiftUI recreates the session object.
        nsView.previewLayer.session = session
    }

    final class PreviewContainerView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            // Create the preview layer with the session immediately — avoids
            // the Big Sur bug where setting .session after init is ignored.
            self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
            self.previewLayer.videoGravity = .resizeAspect
            self.previewLayer.backgroundColor = NSColor.black.cgColor
            super.init(frame: .zero)

            // Let AppKit use our previewLayer as the backing layer (see makeBackingLayer).
            self.wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func makeBackingLayer() -> CALayer {
            // Returning the preview layer itself avoids the sublayer compositing
            // issues seen on Intel Big Sur GPU drivers.
            return previewLayer
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

private final class MultiviewCaptureController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Status: Equatable {
        case idle
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .idle:
                return "Idle"
            case .starting:
                return "Starting…"
            case .running:
                return "Running"
            case .failed(let message):
                return message
            }
        }
    }

    let session = AVCaptureSession()
    let metalPreview = CameraMetalPreviewModel()
    let focusPeakingEngine: Any? = {
        if #available(macOS 14.0, *) {
            do {
                return try FocusPeakingEngine()
            } catch {
                print("Failed to initialize FocusPeakingEngine for tile: \(error)")
                return nil
            }
        }
        return nil
    }()

    @Published private(set) var status: Status = .idle
    @Published var isRecording: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    private var recordingTimer: Timer?
    private let movieFileOutput = AVCaptureMovieFileOutput()
    private var movieFileOutputDelegate: RecordingDelegate?
    private var currentAudioInput: AVCaptureDeviceInput?

    private let sessionQueue = DispatchQueue(label: "MultiviewCaptureController.sessionQueue", qos: .userInitiated)
    private let outputQueue = DispatchQueue(label: "MultiviewCaptureController.videoOutputQueue", qos: .userInitiated)

    // MARK: - Recording Methods

    func startRecording(codec: AVVideoCodecType = .proRes422) {
        sessionQueue.async {
            guard !self.isRecording else { return }

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
            let name = self.requestedUniqueID ?? "Camera"
            let fileName = "Recording_Tile_\(name)_\(dateString).mov"
            let outputURL = documentsPath.appendingPathComponent(fileName)

            self.movieFileOutputDelegate = RecordingDelegate(onFinished: { [weak self] url in
                Task { @MainActor [weak self] in
                    print("Multiview Tile Recording finished: \(url.path)")
                    self?.stopRecordingTimer()
                }
            })

            if let connection = self.movieFileOutput.connection(with: .video) {
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

    func setAudioInput(deviceID: AudioDeviceID?) {
        sessionQueue.async {
            self.session.beginConfiguration()

            if let current = self.currentAudioInput {
                self.session.removeInput(current)
                self.currentAudioInput = nil
            }

            if let id = deviceID, let avDevice = self.findAVAudioDevice(for: id) {
                do {
                    let input = try AVCaptureDeviceInput(device: avDevice)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.currentAudioInput = input
                    }
                } catch {
                    print("Error: Failed to add audio input to tile: \(error)")
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

        var nameBuffer: [CChar] = Array(repeating: 0, count: 256)
        if AudioDevices_GetDeviceName(coreAudioID, &nameBuffer, 256) == noErr {
            let name = String(cString: nameBuffer)
            return devices.first(where: { $0.localizedName == name })
        }

        return nil
    }
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentInput: AVCaptureDeviceInput?
    private var requestedUniqueID: String?
    private var retryWorkItem: DispatchWorkItem?

    func selectCamera(uniqueID: String?) {
        sessionQueue.async {
            self.requestedUniqueID = uniqueID
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.configure(uniqueID: uniqueID, remainingRetries: 3)
        }
    }

    func stop() {
        sessionQueue.async {
            self.requestedUniqueID = nil
            self.retryWorkItem?.cancel()
            self.retryWorkItem = nil
            self.stopSession(removeInput: true, nextStatus: .idle)
        }
    }

    private func configure(uniqueID: String?, remainingRetries: Int) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            publish(.failed("Camera permission not granted"))
            return
        }

        guard requestedUniqueID == uniqueID else {
            return
        }

        guard let uniqueID else {
            stopSession(removeInput: true, nextStatus: .idle)
            return
        }

        if currentInput?.device.uniqueID == uniqueID, session.isRunning {
            publish(.running)
            return
        }

        publish(.starting)

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        guard let device = discovery.devices.first(where: { $0.uniqueID == uniqueID }) else {
            stopSession(removeInput: true, nextStatus: .failed("Camera not found"))
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()
            session.sessionPreset = .medium
            if let currentInput {
                session.removeInput(currentInput)
                self.currentInput = nil
            }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                scheduleRetry(for: uniqueID, remainingRetries: remainingRetries, failureMessage: "Source unavailable")
                return
            }
            session.addInput(input)
            currentInput = input

            if videoOutput == nil {
                let newOutput = AVCaptureVideoDataOutput()
                newOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ]
                newOutput.alwaysDiscardsLateVideoFrames = true
                newOutput.setSampleBufferDelegate(self, queue: outputQueue)
                if session.canAddOutput(newOutput) {
                    session.addOutput(newOutput)
                    videoOutput = newOutput
                }
            }

            session.commitConfiguration()

            if !session.isRunning {
                session.startRunning()
            }

            if session.isRunning {
                publish(.running)
            } else {
                scheduleRetry(for: uniqueID, remainingRetries: remainingRetries, failureMessage: "Camera failed to start")
            }
        } catch {
            scheduleRetry(for: uniqueID, remainingRetries: remainingRetries, failureMessage: error.localizedDescription)
        }
    }

    private func scheduleRetry(for uniqueID: String, remainingRetries: Int, failureMessage: String) {
        guard requestedUniqueID == uniqueID else {
            return
        }

        guard remainingRetries > 0 else {
            stopSession(removeInput: true, nextStatus: .failed(failureMessage))
            return
        }

        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.configure(uniqueID: uniqueID, remainingRetries: remainingRetries - 1)
        }
        retryWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func stopSession(removeInput: Bool, nextStatus: Status) {
        if session.isRunning {
            session.stopRunning()
        }

        if removeInput {
            session.beginConfiguration()
            if let currentInput {
                session.removeInput(currentInput)
                self.currentInput = nil
            }
            session.commitConfiguration()
        }

        publish(nextStatus)
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async {
            self.status = status
        }
    }
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if #available(macOS 14.0, *) {
            metalPreview.enqueue(pixelBuffer: pixelBuffer, timestamp: timestamp, focusEngine: focusPeakingEngine as AnyObject?)
        } else {
            metalPreview.enqueueCompat(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
    }

}

private struct MultiviewPreviewTile: View {
    let slotID: Int
    @Binding var selectedUniqueID: String?
    let devices: [VideoMonitoringModel.CameraDevice]
    let sharedSession: AVCaptureSession
    let unavailableUniqueIDs: Set<String>
    let activePreviewModel: CameraMetalPreviewModel?
    let isActiveSelection: Bool
    let sourceProfile: VideoSourceProfileState?
    @Binding var draggedSlotID: Int?
    let onActivate: () -> Void

    @Environment(\.appUIScale) private var appUIScale
    @StateObject private var controller = MultiviewCaptureController()

    private var scaledTitleFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 11 * appUIScale }

    private var selectedDevice: VideoMonitoringModel.CameraDevice? {
        guard let selectedUniqueID else { return nil }
        return devices.first(where: { $0.uniqueID == selectedUniqueID })
    }

    private var showsActiveMetalPreview: Bool {
        isActiveSelection && activePreviewModel != nil && selectedUniqueID != nil
    }

    private var usesSharedSessionPreview: Bool {
        isActiveSelection && activePreviewModel == nil && selectedUniqueID != nil
    }

    private var showsActivePreview: Bool {
        showsActiveMetalPreview || usesSharedSessionPreview
    }

    private var statusText: String {
        if showsActivePreview {
            return "Active source"
        }
        guard selectedUniqueID != nil else {
            return "Assign a camera source"
        }
        return controller.status.label
    }

    private var overlayState: (title: String, subtitle: String, accent: Color)? {
        guard !showsActivePreview else { return nil }
        guard selectedUniqueID != nil else { return nil }

        switch controller.status {
        case .idle:
            return nil
        case .starting:
            return ("Starting camera", "Opening live preview for this tile.", .secondary)
        case .running:
            return nil
        case .failed(let message):
            return ("Camera unavailable", message, .orange)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDevice?.displayName ?? "Empty Slot")
                        .font(.system(size: scaledTitleFontSize, weight: .semibold))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: scaledCaptionFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isActiveSelection {
                    Text("Active")
                        .font(.system(size: scaledCaptionFontSize, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.14)))
                }

                // Visual-only drag affordance — layout is pure SwiftUI, no NSHostingView wrapper.
                // The actual .onDrag is applied to the outer tile container below.
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: scaledCaptionFontSize, weight: .semibold))
                    .foregroundColor(draggedSlotID == slotID ? .accentColor : .secondary)
                    .padding(6)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(draggedSlotID == slotID ? 0.16 : 0.06))
                    )
                    .allowsHitTesting(false)
            }

            Picker("Source", selection: $selectedUniqueID) {
                Text("Empty Slot").tag(nil as String?)
                ForEach(devices) { device in
                    Text(device.displayName)
                        .tag(device.uniqueID as String?)
                        .disabled(selectedUniqueID != device.uniqueID && unavailableUniqueIDs.contains(device.uniqueID))
                }
            }
            .pickerStyle(.menu)

            ZStack {
                // Base layer: always keep the per-tile session preview alive so the
                // AVCaptureVideoPreviewLayer is never destroyed between active/inactive
                // transitions — destroying it causes the brief black flash on other tiles.
                if selectedUniqueID != nil {
                    NativePreviewLayerView(session: controller.session)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 18))
                            .foregroundColor(.secondary)
                        Text("No camera assigned")
                            .font(.system(size: scaledCaptionFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }

                // Active overlays drawn on top — Metal or shared-session preview
                // when this tile is the active selection.
                if showsActiveMetalPreview, let activePreviewModel {
                    CameraMetalPreviewView(model: activePreviewModel)
                } else if usesSharedSessionPreview {
                    NativePreviewLayerView(session: sharedSession)
                } else if selectedUniqueID != nil, activePreviewModel != nil {
                    CameraMetalPreviewView(model: controller.metalPreview)
                } else if selectedUniqueID != nil {
                    NativePreviewLayerView(session: controller.session)
                }

                if let overlayState {
                    VStack(spacing: 6) {
                        Text(overlayState.title)
                            .font(.system(size: scaledTitleFontSize, weight: .semibold))
                            .foregroundColor(.white)
                        Text(overlayState.subtitle)
                            .font(.system(size: scaledCaptionFontSize, weight: .regular))
                            .foregroundColor(overlayState.accent)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 170)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.black.opacity(0.62))
                    )
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.32))
            .clipShape(ThemeRoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActiveSelection ? Color.accentColor : Color.white.opacity(showsActivePreview ? 0.24 : 0.12), lineWidth: isActiveSelection ? 1.6 : 1)
            )
            .contentShape(ThemeRoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                onActivate()
            }
        }
        .padding(10)
        .background(
            ThemeRoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.08))
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isActiveSelection ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.10), lineWidth: isActiveSelection ? 1.4 : 1)
                )
        )
        .contentShape(ThemeRoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            onActivate()
        }
        .onDrag {
            draggedSlotID = slotID
            return NSItemProvider(object: NSString(string: String(slotID)))
        }
        .help("Drag to reorder this source")
        .onAppear {
            if #available(macOS 14.0, *) {
                controller.metalPreview.focusPeakingEngine = controller.focusPeakingEngine as AnyObject?
            }
            syncController()
            if let profile = sourceProfile {
                controller.metalPreview.applyPersistedState(profile.preview)
                applyFocusPeakingProfileState(profile.focusPeaking)
            }
        }
        .onChange(of: sourceProfile?.preview) { newPreviewState in
            if let previewState = newPreviewState {
                controller.metalPreview.applyPersistedState(previewState)
            } else {
                controller.metalPreview.applyPersistedState(CameraMetalPreviewModel.PersistedState())
            }
            if let fpState = sourceProfile?.focusPeaking {
                applyFocusPeakingProfileState(fpState)
            } else {
                applyFocusPeakingProfileState(FocusPeakingProfileState())
            }
        }
        .onChange(of: selectedUniqueID) { _ in
            syncController()
        }
        .onChange(of: isActiveSelection) { _ in
            syncController()
        }
        .onDisappear {
            controller.stop()
        }
    }

    private func syncController() {
        // Always keep the personal session running regardless of active/inactive state.
        // When isActiveSelection is true the ZStack overlays Metal/shared preview, but
        // keeping the session warm means deactivation is instant — no cold-restart, no black flash.
        // The session is only stopped in onDisappear when the tile is truly gone.
        controller.selectCamera(uniqueID: selectedUniqueID)
    }

    private func applyFocusPeakingProfileState(_ state: FocusPeakingProfileState) {
        if #available(macOS 14.0, *),
           let engine = controller.focusPeakingEngine as? FocusPeakingEngine {
            engine.isEnabled = state.isEnabled
            engine.settings = state.settings
        }
    }
}

// Note: WindowDragBlockingHostingView was removed — the tile's .onDrag modifier
// is now applied directly to the outer container, which is sufficient for
// drag-and-drop reorder. If the host window ever needs per-tile mouseDownCanMoveWindow
// overrides, a lightweight NSView-based blocker (not NSHostingView) can be added back.

private struct MultiviewTileReorderDropDelegate: DropDelegate {
    let destinationIndex: Int
    let destinationSlotID: Int
    @Binding var slots: [MultiviewSlot]
    @Binding var draggedSlotID: Int?

    func dropEntered(info: DropInfo) {
        guard let draggedSlotID,
              draggedSlotID != destinationSlotID,
              let fromIndex = slots.firstIndex(where: { $0.id == draggedSlotID }),
              let currentDestinationIndex = slots.firstIndex(where: { $0.id == destinationSlotID }) else { return }

        if fromIndex == currentDestinationIndex {
            return
        }

        let movedSlot = slots.remove(at: fromIndex)
        let resolvedDestinationIndex = min(max(destinationIndex, 0), slots.count)
        let insertionIndex = currentDestinationIndex > fromIndex ? min(resolvedDestinationIndex, slots.count) : min(currentDestinationIndex, slots.count)
        slots.insert(movedSlot, at: insertionIndex)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedSlotID = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if !info.hasItemsConforming(to: [UTType.plainText.identifier]) {
            draggedSlotID = nil
        }
    }
}

// MARK: - Draggable Divider
private struct DraggableDivider: View {
    @Binding var splitRatio: CGFloat
    let containerWidth: CGFloat
    @State private var isDragging = false
    @State private var isHovering = false

    private let handleWidth: CGFloat = 10
    private let handleHeight: CGFloat = 40

    var body: some View {
        DividerHandleView(
            splitRatio: $splitRatio,
            containerWidth: containerWidth,
            isDragging: $isDragging,
            isHovering: $isHovering,
            handleWidth: handleWidth,
            handleHeight: handleHeight
        )
    }
}

// NSView-based divider that properly intercepts mouse events
private struct DividerHandleView: NSViewRepresentable {
    @Binding var splitRatio: CGFloat
    let containerWidth: CGFloat
    @Binding var isDragging: Bool
    @Binding var isHovering: Bool
    let handleWidth: CGFloat
    let handleHeight: CGFloat

    func makeNSView(context: Context) -> DividerNSView {
        let view = DividerNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: DividerNSView, context: Context) {
        context.coordinator.splitRatio = $splitRatio
        context.coordinator.containerWidth = containerWidth
        context.coordinator.isDragging = $isDragging
        context.coordinator.isHovering = $isHovering
        context.coordinator.handleWidth = handleWidth
        context.coordinator.handleHeight = handleHeight
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            splitRatio: $splitRatio,
            containerWidth: containerWidth,
            isDragging: $isDragging,
            isHovering: $isHovering,
            handleWidth: handleWidth,
            handleHeight: handleHeight
        )
    }

    final class Coordinator {
        var splitRatio: Binding<CGFloat>
        var containerWidth: CGFloat
        var isDragging: Binding<Bool>
        var isHovering: Binding<Bool>
        var handleWidth: CGFloat
        var handleHeight: CGFloat

        init(splitRatio: Binding<CGFloat>, containerWidth: CGFloat, isDragging: Binding<Bool>, isHovering: Binding<Bool>, handleWidth: CGFloat, handleHeight: CGFloat) {
            self.splitRatio = splitRatio
            self.containerWidth = containerWidth
            self.isDragging = isDragging
            self.isHovering = isHovering
            self.handleWidth = handleWidth
            self.handleHeight = handleHeight
        }
    }

    final class DividerNSView: NSView {
        weak var coordinator: Coordinator?
        private var trackingArea: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setupTrackingArea()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupTrackingArea()
        }

        // Critical: Prevent this view from being used to drag the window
        override var mouseDownCanMoveWindow: Bool {
            return false
        }

        private func setupTrackingArea() {
            let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
            trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            if let trackingArea = trackingArea {
                addTrackingArea(trackingArea)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea = trackingArea {
                removeTrackingArea(trackingArea)
            }
            setupTrackingArea()
        }

        override func mouseEntered(with event: NSEvent) {
            coordinator?.isHovering.wrappedValue = true
            NSCursor.resizeLeftRight.push()
        }

        override func mouseExited(with event: NSEvent) {
            coordinator?.isHovering.wrappedValue = false
            NSCursor.pop()
        }

        override func mouseDown(with event: NSEvent) {
            guard let coordinator = coordinator else { return }

            coordinator.isDragging.wrappedValue = true

            // Store the initial mouse position relative to the divider
            let initialMouseInWindow = event.locationInWindow
            let initialRatio = coordinator.splitRatio.wrappedValue

            var keepTracking = true
            while keepTracking {
                guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                    break
                }

                switch nextEvent.type {
                case .leftMouseDragged:
                    // Calculate delta from initial position to avoid layout feedback loops
                    let currentMouseInWindow = nextEvent.locationInWindow
                    let deltaX = currentMouseInWindow.x - initialMouseInWindow.x

                    // Convert delta to ratio change
                    let deltaRatio = deltaX / coordinator.containerWidth
                    let newRatio = initialRatio + deltaRatio

                    // Clamp between 30% and 70% to keep both sides visible
                    let clampedRatio = min(max(newRatio, 0.3), 0.7)

                    // Update immediately on the main thread (we're already in event tracking mode)
                    coordinator.splitRatio.wrappedValue = clampedRatio

                case .leftMouseUp:
                    keepTracking = false
                    coordinator.isDragging.wrappedValue = false

                default:
                    break
                }
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            guard let coordinator = coordinator else { return }

            // Draw the handle in the center
            let handleWidth = coordinator.handleWidth
            let handleHeight = coordinator.handleHeight
            let handleX = (bounds.width - handleWidth) / 2
            let handleY = (bounds.height - handleHeight) / 2

            let handleRect = NSRect(x: handleX, y: handleY, width: handleWidth, height: handleHeight)
            let handlePath = NSBezierPath(roundedRect: handleRect, xRadius: handleWidth / 2, yRadius: handleWidth / 2)

            // Choose color based on state
            let color: NSColor
            if coordinator.isDragging.wrappedValue {
                color = NSColor.controlAccentColor.withAlphaComponent(0.5)
            } else if coordinator.isHovering.wrappedValue {
                color = NSColor.secondaryLabelColor.withAlphaComponent(0.4)
            } else {
                color = NSColor.secondaryLabelColor.withAlphaComponent(0.2)
            }

            color.setFill()
            handlePath.fill()
        }
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
            print("Error: Recording error: \(error.localizedDescription)")
        }
        onFinished?(outputFileURL)
    }
}
