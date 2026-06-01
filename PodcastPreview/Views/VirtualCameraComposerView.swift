import SwiftUI
import AVFoundation
import Combine
import AVKit
import AppKit
import PodcastPreviewCore
import UniformTypeIdentifiers

struct VirtualCameraComposerView: View {
    @ObservedObject var composer = VirtualCameraComposerModel.shared
    @ObservedObject var driverService = VirtualCameraDriverService.shared
    @Environment(\.appUIScale) private var appUIScale
    @State private var selectedLayerID: UUID?
    @State private var showingTextStylePopover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Left Panel: Layer List
                layerListPanel

                // Center: Canvas / Preview
                canvasPanel

                // Right Panel: Layer Properties
                propertiesPanel
            }

            VirtualCameraComposerHealthToolbar(
                composer: composer,
                publisher: VirtualCameraPublisher.shared,
                driverService: driverService
            )
        }
        .background(Color.clear)
        .onAppear {
            composer.refreshDevices()
            driverService.refreshStatus()
            if composer.layers.isEmpty {
                composer.addLayer(type: .videoSource)
                selectedLayerID = composer.layers.first?.id
            } else if selectedLayerID == nil {
                selectedLayerID = composer.layers.first?.id
            }
        }
    }

    private var layerListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layers")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Video Source") { composer.addLayer(type: .videoSource) }
                    Button("Media File") { composer.addLayer(type: .mediaFile) }
                    Button("Image") { composer.addLayer(type: .image) }
                    Button("Text") { composer.addLayer(type: .text) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                }
                .menuStyle(.borderlessButton)
            }
            .padding()

            Divider().background(Color.white.opacity(0.1))

            List {
                ForEach(composer.layers) { layer in
                    LayerRow(
                        layer: layer,
                        subtitle: rowSubtitle(for: layer),
                        isSelected: selectedLayerID == layer.id
                    )
                        .onTapGesture { selectedLayerID = layer.id }
                }
                .onMove(perform: composer.moveLayer)
                .onDelete(perform: deleteLayers)
            }
            .listStyle(.plain)

            Spacer()

            // Output Toggle
            VStack(spacing: 12) {
                Divider().background(Color.white.opacity(0.1))
                Button(action: { composer.toggleOutput() }) {
                    HStack {
                        Image(systemName: composer.isOutputActive ? "stop.fill" : "play.fill")
                        Text(composer.isOutputActive ? "Stop Virtual Camera" : "Start Virtual Camera")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(composer.isOutputActive ? Color.red.opacity(0.3) : Color.green.opacity(0.3))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .padding()
            }
        }
        .frame(width: 250)
        .background(Color.black.opacity(0.14))
    }

    private var canvasPanel: some View {
        let renderSnapshot = composer.makeRenderSnapshot()
        let aspectRatio = renderSnapshot.canvasSize.width / max(renderSnapshot.canvasSize.height, 1)

        return VStack(spacing: 0) {
            // Canvas Area
            ZStack {
                Color.black

                // Checkerboard pattern for transparency
                checkerboardBackground

                // Layers (rendered in reverse order for Z-index)
                GeometryReader { geometry in
                    ForEach(renderSnapshot.layers.reversed()) { layer in
                        ComposerLayerPreview(layer: layer, canvasSize: geometry.size)
                    }
                }

                // Canvas Border
                Rectangle()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            .padding(40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var checkerboardBackground: some View {
        GeometryReader { geo in
            Path { path in
                let size: CGFloat = 20
                let cols = Int(geo.size.width / size) + 1
                let rows = Int(geo.size.height / size) + 1

                for row in 0..<rows {
                    for col in 0..<cols {
                        if (row + col) % 2 == 0 {
                            path.addRect(CGRect(x: CGFloat(col) * size, y: CGFloat(row) * size, width: size, height: size))
                        }
                    }
                }
            }
            .fill(Color.white.opacity(0.03))
        }
    }

    private var propertiesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Properties")
                .font(.headline)
                .padding()

            Divider().background(Color.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PropertySection(title: "Virtual Camera Driver") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(driverService.driverBundleName)
                                .font(.subheadline.weight(.semibold))
                            Text(driverService.statusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                Button(action: { composer.installDriver() }) {
                                    Text(driverService.actionInProgress ? "Working…" : (driverService.isInstalled ? "Repair Driver" : "Install Driver"))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(driverService.actionInProgress || !driverService.isBundledPayloadAvailable)

                                Button(action: { composer.uninstallDriver() }) {
                                    Text("Uninstall")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(driverService.actionInProgress || !driverService.isInstalled)
                            }
                        }
                    }

                    if let selectedID = selectedLayerID,
                       let index = composer.layers.firstIndex(where: { $0.id == selectedID }) {
                        let layer = composer.layers[index]

                        PropertySection(title: "Common") {
                            VStack(alignment: .leading, spacing: 12) {
                                TextField("Name", text: $composer.layers[index].name)
                                    .textFieldStyle(.roundedBorder)

                                PropertyRow(label: "Opacity") {
                                    HStack(spacing: 10) {
                                        Slider(value: $composer.layers[index].opacity, in: 0...1)
                                        Text("\(Int((composer.layers[index].opacity * 100).rounded()))%")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .frame(width: 40, alignment: .trailing)
                                    }
                                }
                            }
                        }

                        PropertySection(title: "Transform") {
                            LayerTransformControls(layer: composer.layers[index])
                        }

                        if layer.type == .text {
                            PropertySection(title: "Text Settings") {
                                VStack(alignment: .leading, spacing: 12) {
                                    TextEditor(text: $composer.layers[index].text)
                                        .frame(height: 96)
                                        .cornerRadius(4)
                                        .font(.system(size: 12))

                                    Button("Style, Format & Layout…") {
                                        showingTextStylePopover = true
                                    }
                                    .buttonStyle(.bordered)
                                    .popover(isPresented: $showingTextStylePopover) {
                                        TextLayerSettingsPopover(
                                            layer: composer.layers[index],
                                            availableFontFamilies: composer.availableFontFamilies
                                        )
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Font: \(composer.layers[index].fontFamily)")
                                        Text("Size: \(Int(composer.layers[index].fontSize.rounded())) pt • Alignment: \(composer.layers[index].textAlignment.rawValue)")
                                        Text("Style: \(composer.layers[index].isBold ? "Bold" : "Regular")\(composer.layers[index].isItalic ? " • Italic" : "")")
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                }
                            }
                        } else if layer.type == .videoSource {
                            PropertySection(title: "Video Settings") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Source Device")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Picker("", selection: $composer.layers[index].videoDeviceID) {
                                        Text("None").tag(nil as String?)
                                        ForEach(composer.availableVideoDevices) { device in
                                            Text(device.displayName).tag(device.uniqueID as String?)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .onChange(of: composer.layers[index].videoDeviceID) { _ in
                                        composer.updateSourceNameIfNeeded(for: composer.layers[index])
                                    }

                                    Text(composer.cameraDisplayName(for: composer.layers[index].videoDeviceID) ?? "No matching camera source detected")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else if layer.type == .mediaFile {
                            PropertySection(title: "Media File") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Picker("Source Type", selection: $composer.layers[index].mediaKind) {
                                        ForEach(VirtualCameraLayer.FileSourceKind.allCases) { kind in
                                            Text(kind.rawValue).tag(kind)
                                        }
                                    }
                                    .pickerStyle(.segmented)

                                    if let url = layer.mediaURL {
                                        Text(url.lastPathComponent)
                                            .font(.caption2)
                                            .lineLimit(1)
                                    } else {
                                        Text("No media file selected")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Button("Select Media…") {
                                        selectMediaFile(for: layer)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        } else if layer.type == .image {
                            PropertySection(title: "Image Settings") {
                                VStack(alignment: .leading, spacing: 12) {
                                    if let url = layer.imageURL {
                                        Text(url.lastPathComponent)
                                            .font(.caption2)
                                            .lineLimit(1)
                                    } else {
                                        Text("No image selected")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Button("Select Image…") {
                                        selectImage(for: layer)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }

                        Button(action: {
                            composer.removeLayer(id: layer.id)
                            selectedLayerID = composer.layers.first?.id
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Layer")
                            }
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 20)
                    } else {
                        VStack {
                            Text("Select a layer to edit properties")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 32)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
        }
        .frame(width: 320)
        .background(Color.black.opacity(0.14))
    }

    private func deleteLayers(at offsets: IndexSet) {
        for index in offsets {
            let id = composer.layers[index].id
            if selectedLayerID == id { selectedLayerID = nil }
            composer.removeLayer(id: id)
        }

        if selectedLayerID == nil {
            selectedLayerID = composer.layers.first?.id
        }
    }

    private func rowSubtitle(for layer: VirtualCameraLayer) -> String? {
        let recognizedName = composer.recognizedSourceName(for: layer)
        return recognizedName == layer.name ? nil : recognizedName
    }

    private func selectImage(for layer: VirtualCameraLayer) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]

        if panel.runModal() == .OK {
            layer.imageURL = panel.url
            composer.updateSourceNameIfNeeded(for: layer)
        }
    }

    private func selectMediaFile(for layer: VirtualCameraLayer) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]

        if panel.runModal() == .OK {
            layer.mediaURL = panel.url
            if let contentType = try? panel.url?.resourceValues(forKeys: [.contentTypeKey]).contentType {
                layer.mediaKind = contentType.conforms(to: .movie) ? .movie : .image
            }
            composer.updateSourceNameIfNeeded(for: layer)
        }
    }
}

private struct LayerRow: View {
    @ObservedObject var layer: VirtualCameraLayer
    let subtitle: String?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center) {
            Image(systemName: iconForType(layer.type))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(layer.name)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: { layer.isVisible.toggle() }) {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(layer.isVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
    }

    private func iconForType(_ type: VirtualCameraLayer.LayerType) -> String {
        switch type {
        case .videoSource: return "video.fill"
        case .mediaFile: return "film.stack.fill"
        case .image: return "photo.fill"
        case .text: return "text.alignleft"
        }
    }
}

private struct PropertySection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption)
                .fontWeight(.bold)
                .textCase(.uppercase)
                .foregroundColor(.secondary)
            content
            Divider().background(Color.white.opacity(0.05))
        }
    }
}

private struct PropertyRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            content
        }
    }
}

private struct LayerTransformControls: View {
    @ObservedObject var layer: VirtualCameraLayer

    private var scaleBinding: Binding<Double> {
        Binding(
            get: { Double(layer.scale) },
            set: { layer.scale = CGFloat($0) }
        )
    }

    private var xBinding: Binding<Double> {
        Binding(
            get: { Double(layer.position.x) },
            set: { layer.position = CGPoint(x: CGFloat($0), y: layer.position.y) }
        )
    }

    private var yBinding: Binding<Double> {
        Binding(
            get: { Double(layer.position.y) },
            set: { layer.position = CGPoint(x: layer.position.x, y: CGFloat($0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PropertyRow(label: "Scale") {
                HStack(spacing: 10) {
                    Slider(value: scaleBinding, in: 0.1...5)
                    Text(String(format: "%.2fx", layer.scale))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            PropertyRow(label: "Rotation") {
                HStack(spacing: 10) {
                    Slider(value: $layer.rotationDegrees, in: -360...360)
                    Text("\(Int(layer.rotationDegrees.rounded()))°")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            PropertyRow(label: "X Position") {
                HStack(spacing: 10) {
                    Slider(value: xBinding, in: -960...960)
                    Text("\(Int(layer.position.x.rounded()))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

            PropertyRow(label: "Y Position") {
                HStack(spacing: 10) {
                    Slider(value: yBinding, in: -540...540)
                    Text("\(Int(layer.position.y.rounded()))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }
}

private struct TextLayerSettingsPopover: View {
    @ObservedObject var layer: VirtualCameraLayer
    let availableFontFamilies: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Font", selection: $layer.fontFamily) {
                    ForEach(availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)

                ColorPicker("Text Color", selection: $layer.textColor)

                HStack(spacing: 12) {
                    Toggle("Bold", isOn: $layer.isBold)
                    Toggle("Italic", isOn: $layer.isItalic)
                }

                Picker("Alignment", selection: $layer.textAlignment) {
                    ForEach(VirtualCameraLayer.TextAlignmentOption.allCases) { alignment in
                        Text(alignment.rawValue).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)

                PropertyRow(label: "Font Size") {
                    HStack(spacing: 10) {
                        Slider(value: $layer.fontSize, in: 8...240)
                        Text("\(Int(layer.fontSize.rounded())) pt")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }

                LayerTransformControls(layer: layer)
            }
            .padding(16)
        }
        .frame(width: 340, height: 420)
    }
}

@MainActor
private final class ComposerCameraPreviewController: ObservableObject {
    @Published private(set) var captureSource: VirtualCameraCaptureSource?

    private var currentDeviceID: String?

    init(deviceID: String?) {
        update(deviceID: deviceID)
    }

    deinit {
        if let currentDeviceID {
            Task { @MainActor [currentDeviceID] in
                VirtualCameraCaptureSourcePool.shared.release(uniqueID: currentDeviceID)
            }
        }
    }

    func update(deviceID: String?) {
        guard currentDeviceID != deviceID else { return }

        if let currentDeviceID {
            VirtualCameraCaptureSourcePool.shared.release(uniqueID: currentDeviceID)
        }

        currentDeviceID = deviceID

        if let deviceID {
            captureSource = VirtualCameraCaptureSourcePool.shared.acquire(uniqueID: deviceID)
        } else {
            captureSource = nil
        }
    }
}

@MainActor
private final class ComposerMoviePreviewController: ObservableObject {
    let player = AVQueuePlayer()

    private var currentURL: URL?
    private var looper: AVPlayerLooper?

    init(url: URL?) {
        player.isMuted = true
        player.actionAtItemEnd = .none
        update(url: url)
    }

    deinit {
        player.pause()
        player.removeAllItems()
        looper = nil
    }

    func update(url: URL?) {
        guard currentURL != url else { return }

        player.pause()
        player.removeAllItems()
        looper = nil
        currentURL = url

        guard let url else { return }

        let templateItem = AVPlayerItem(asset: AVAsset(url: url))
        looper = AVPlayerLooper(player: player, templateItem: templateItem)
        player.play()
    }
}

private struct ComposerCameraLiveContent: View {
    let deviceID: String?
    let displayName: String?

    @StateObject private var controller: ComposerCameraPreviewController

    init(deviceID: String?, displayName: String?) {
        self.deviceID = deviceID
        self.displayName = displayName
        _controller = StateObject(wrappedValue: ComposerCameraPreviewController(deviceID: deviceID))
    }

    var body: some View {
        Group {
            if let source = controller.captureSource {
                ComposerCapturePreviewLayerView(session: source.session)
                    .background(Color.black)
            } else {
                ZStack {
                    Color.blue.opacity(0.18)
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill")
                        Text(displayName ?? "No Camera Source")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .clipped()
        .onChange(of: deviceID) { newValue in
            controller.update(deviceID: newValue)
        }
        .onDisappear {
            controller.update(deviceID: nil)
        }
    }
}

private struct ComposerMovieLiveContent: View {
    let url: URL

    @StateObject private var controller: ComposerMoviePreviewController

    init(url: URL) {
        self.url = url
        _controller = StateObject(wrappedValue: ComposerMoviePreviewController(url: url))
    }

    var body: some View {
        ComposerPlayerView(player: controller.player)
            .background(Color.black)
            .clipped()
            .onChange(of: url) { newValue in
                controller.update(url: newValue)
            }
            .onDisappear {
                controller.update(url: nil)
            }
    }
}

private struct ComposerCapturePreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewContainerView {
        PreviewContainerView(session: session)
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        nsView.previewLayer.session = session
    }

    final class PreviewContainerView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspect
            previewLayer.backgroundColor = NSColor.black.cgColor
            super.init(frame: .zero)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func makeBackingLayer() -> CALayer {
            previewLayer
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

private struct ComposerPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

private struct ComposerLayerPreview: View {
    let layer: VirtualCameraRenderLayerSnapshot
    let canvasSize: CGSize

    var body: some View {
        Group {
            if layer.isVisible {
                content
                    .frame(width: contentSize.width, height: contentSize.height)
                    .opacity(Double(layer.opacity))
                    .scaleEffect(layer.scale)
                    .rotationEffect(.degrees(layer.rotationDegrees))
                    .position(layer.anchor(in: canvasSize))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layer.source {
        case let .videoSource(deviceID, displayName):
            ComposerCameraLiveContent(deviceID: deviceID, displayName: displayName)
        case let .image(url):
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "photo").foregroundColor(.white.opacity(0.3)))
            }
        case let .mediaFile(url, kind):
            if kind == .image,
               let url,
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if kind == .movie,
                      let url {
                ComposerMovieLiveContent(url: url)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.purple.opacity(0.18))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: kind == .movie ? "film" : "doc")
                            Text(url?.lastPathComponent ?? "No Media File")
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(.white.opacity(0.62))
                        .padding(12)
                    )
            }
        case let .text(textStyle):
            styledText(textStyle)
                .foregroundColor(textStyle.color.swiftUIColor)
                .multilineTextAlignment(textAlignment(for: textStyle.alignment))
                .frame(width: contentSize.width, height: contentSize.height, alignment: frameAlignment(for: textStyle.alignment))
        }
    }

    private var contentSize: CGSize {
        switch layer.source {
        case .videoSource:
            return layer.fittedContentSize(for: CGSize(width: 1920, height: 1080), in: canvasSize)
        case let .image(url):
            let sourceSize = imageSize(for: url)
            return layer.fittedContentSize(for: sourceSize, in: canvasSize)
        case let .mediaFile(url, kind):
            switch kind {
            case .image:
                return layer.fittedContentSize(for: imageSize(for: url), in: canvasSize)
            case .movie:
                return layer.fittedContentSize(for: movieSize(for: url), in: canvasSize)
            }
        case .text:
            let bounds = layer.textBoundingRect(in: canvasSize)
            return CGSize(width: max(bounds.width, 1), height: max(bounds.height, 1))
        }
    }

    private func styledText(_ textStyle: VirtualCameraRenderTextStyle) -> Text {
        var text = Text(textStyle.text)
            .font(.custom(textStyle.fontFamily, size: textStyle.fontSize))

        if textStyle.isBold {
            text = text.bold()
        }

        if textStyle.isItalic {
            text = text.italic()
        }

        return text
    }

    private func textAlignment(for alignment: VirtualCameraLayer.TextAlignmentOption) -> TextAlignment {
        switch alignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    private func frameAlignment(for alignment: VirtualCameraLayer.TextAlignmentOption) -> Alignment {
        switch alignment {
        case .leading:
            return .leading
        case .center:
            return .center
        case .trailing:
            return .trailing
        }
    }

    private func imageSize(for url: URL?) -> CGSize {
        guard let url, let image = NSImage(contentsOf: url) else {
            return CGSize(width: 1920, height: 1080)
        }
        return image.size
    }

    private func movieSize(for url: URL?) -> CGSize {
        guard let url else {
            return CGSize(width: 1920, height: 1080)
        }
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return CGSize(width: 1920, height: 1080)
        }
        let transformedSize = track.naturalSize.applying(track.preferredTransform)
        let width = max(abs(transformedSize.width), 1)
        let height = max(abs(transformedSize.height), 1)
        return CGSize(width: width, height: height)
    }
}
