import SwiftUI
import PodcastPreviewShared
import Metal
import MetalKit

// MARK: - CPU Core Meters

struct CPUCoreMetersView: View {
    @Environment(\.appUIScale) private var appUIScale
    let cores: [Float]

    private var scaledStackSpacing: CGFloat { 6 * appUIScale }
    private var scaledRowHeight: CGFloat { 16 * appUIScale }
    private var scaledBarHeight: CGFloat { 6 * appUIScale }
    private var scaledBarCornerRadius: CGFloat { 4 * appUIScale }
    private var scaledCoreLabelWidth: CGFloat { 60 * appUIScale }
    private var scaledPercentLabelWidth: CGFloat { 40 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }

    var body: some View {
        VStack(spacing: scaledStackSpacing) {
            ForEach(cores.indices, id: \.self) { index in
                HStack {
                    Text("Core \(index + 1)")
                        .font(.system(size: scaledCaptionFontSize, weight: .regular))
                        .frame(width: scaledCoreLabelWidth, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            ThemeRoundedRectangle(cornerRadius: scaledBarCornerRadius)
                                .fill(Color.blue.opacity(0.15))

                            ThemeRoundedRectangle(cornerRadius: scaledBarCornerRadius)
                                .fill(usageColor(for: cores[index]))
                                .frame(width: geo.size.width * CGFloat(cores[index]))
                        }
                    }
                    .frame(height: scaledBarHeight)

                    Text(String(format: "%3.0f%%", cores[index] * 100))
                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                        .frame(width: scaledPercentLabelWidth, alignment: .trailing)
                }
                .frame(height: scaledRowHeight)
            }
        }
    }

    private func usageColor(for value: Float) -> Color {
        switch value {
        case 0.75...:
            return Color.blue.opacity(0.9)
        case 0.4...:
            return Color.blue.opacity(0.6)
        default:
            return Color.blue.opacity(0.35)
        }
    }
}

// MARK: - Metal CPU Core Meters

struct MetalCPUCoreMetersView: NSViewRepresentable {
    @Environment(\.appUIScale) private var appUIScale
    let cores: [Float]

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = NSColor.clear.cgColor
        }

        if let renderer = HardwareMetersRenderer(mtkView: view) {
            context.coordinator.renderer = renderer
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        nsView.layer?.contentsScale = max(appUIScale, 0.75)

        let now = Date().timeIntervalSinceReferenceDate
        let forceRedraw = now - context.coordinator.lastRedrawTime >= 0.5
        let significantChange = metalArrayChangedSignificantly(
            cores, context.coordinator.lastRenderedCores, threshold: 0.05
        )
        guard forceRedraw || (now - context.coordinator.lastRedrawTime >= 0.05 && significantChange) else { return }

        renderer.update(coreUsages: cores)
        context.coordinator.lastRenderedCores = cores
        context.coordinator.lastRedrawTime = now
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var renderer: HardwareMetersRenderer?
        var lastRedrawTime: TimeInterval = 0
        var lastRenderedCores: [Float] = []
    }
}

// MARK: - Metal Pressure Meter (legacy; replaced by graph)

struct MetalPressureMeterView: NSViewRepresentable {
    let value: Float

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = NSColor.clear.cgColor
        }

        if let renderer = PressureMeterRenderer(mtkView: view) {
            context.coordinator.renderer = renderer
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let forceRedraw = now - context.coordinator.lastRedrawTime >= 0.5
        let significantChange = abs(value - context.coordinator.lastRenderedValue) > 0.05
        guard forceRedraw || (now - context.coordinator.lastRedrawTime >= 0.05 && significantChange) else { return }

        renderer.value = value
        context.coordinator.lastRenderedValue = value
        context.coordinator.lastRedrawTime = now
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: PressureMeterRenderer?
        var lastRedrawTime: TimeInterval = 0
        var lastRenderedValue: Float = -1
    }
}

final class PressureMeterRenderer: NSObject, MTKViewDelegate {
    struct Vertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
        var uv: SIMD2<Float>
        var level: Float
        var _pad: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var vertexBuffer: MTLBuffer?

    var value: Float = 0

    init?(mtkView: MTKView) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let device = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "meter_vertex",
                fragmentFunctionName: "meter_fragment",
                pixelFormat: .bgra8Unorm,
                blendingMode: .opaque
              ) else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipelineState

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        super.init()
        mtkView.delegate = self
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        commandBuffer.label = "PressureMeterRenderer.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        encoder.setRenderPipelineState(pipelineState)

        let vertices = buildVertices()
        let length = vertices.count * MemoryLayout<Vertex>.stride

        if vertexBuffer == nil || vertexBuffer!.length < length {
            vertexBuffer = device.makeBuffer(length: length, options: .storageModeShared)
        }

        memcpy(vertexBuffer!.contents(), vertices, length)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func buildVertices() -> [Vertex] {
        let v = max(0, min(value, 1))

        let xLeft: Float = -1.0
        let xFullRight: Float = 1.0
        let xRight: Float = -1.0 + v * 2.0

        let yBottom: Float = -1.0
        let yTop: Float = 1.0

        let base = SIMD4<Float>(0.10, 0.55, 0.25, 1.0)
        let background = SIMD4<Float>(0.0, 0.0, 0.0, 0.10)

        let uvXLeft: Float = 0.0
        let uvXRight: Float = (xRight + 1.0) * 0.5
        let uvXFullRight: Float = 1.0

        var verts: [Vertex] = []
        verts.reserveCapacity(12)

        verts.append(Vertex(position: SIMD2<Float>(xLeft, yBottom), color: background, uv: SIMD2<Float>(uvXLeft, 0), level: 0, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xFullRight, yBottom), color: background, uv: SIMD2<Float>(uvXFullRight, 0), level: 0, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xLeft, yTop), color: background, uv: SIMD2<Float>(uvXLeft, 1), level: 0, _pad: 0))

        verts.append(Vertex(position: SIMD2<Float>(xFullRight, yBottom), color: background, uv: SIMD2<Float>(uvXFullRight, 0), level: 0, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xFullRight, yTop), color: background, uv: SIMD2<Float>(uvXFullRight, 1), level: 0, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xLeft, yTop), color: background, uv: SIMD2<Float>(uvXLeft, 1), level: 0, _pad: 0))

        verts.append(Vertex(position: SIMD2<Float>(xLeft, yBottom), color: base, uv: SIMD2<Float>(uvXLeft, 0), level: v, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xRight, yBottom), color: base, uv: SIMD2<Float>(uvXRight, 0), level: v, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xLeft, yTop), color: base, uv: SIMD2<Float>(uvXLeft, 1), level: v, _pad: 0))

        verts.append(Vertex(position: SIMD2<Float>(xRight, yBottom), color: base, uv: SIMD2<Float>(uvXRight, 0), level: v, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xRight, yTop), color: base, uv: SIMD2<Float>(uvXRight, 1), level: v, _pad: 0))
        verts.append(Vertex(position: SIMD2<Float>(xLeft, yTop), color: base, uv: SIMD2<Float>(uvXLeft, 1), level: v, _pad: 0))

        return verts
    }
}

// MARK: - Usage History Graphs

struct MetalUsageGraphView: NSViewRepresentable {
    let values: [Float]
    let lineColor: SIMD4<Float>

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let renderer = HardwareGraphsRenderer(mtkView: view) {
            renderer.update(values: values, lineColor: lineColor)
            context.coordinator.renderer = renderer
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let forceRedraw = now - context.coordinator.lastRedrawTime >= 0.5
        let significantChange = metalArrayChangedSignificantly(
            values, context.coordinator.lastRenderedValues, threshold: 0.05
        )
        guard forceRedraw || (now - context.coordinator.lastRedrawTime >= 0.05 && significantChange) else { return }

        renderer.update(values: values, lineColor: lineColor)
        context.coordinator.lastRenderedValues = values
        context.coordinator.lastRedrawTime = now
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var renderer: HardwareGraphsRenderer?
        var lastRedrawTime: TimeInterval = 0
        var lastRenderedValues: [Float] = []
    }
}

struct UsageHistoryCard: View {
    @Environment(\.appUIScale) private var appUIScale
    @Environment(\.floatingMonitorSource) private var floatingMonitorSource
    @Environment(\.graphShowGridlines) private var showGridlines
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let title: String
    let current: Float?
    private let historyProvider: () -> [Float]
    var useMetalGraph: Bool = false
    var metalLineColor: SIMD4<Float> = SIMD4<Float>(0.25, 0.55, 1.0, 1.0)
    var unitLabel: String? = nil
    var currentText: String? = nil
    var secondaryText: String? = nil
    var currentTextLineLimit: Int = 1
    var secondaryTextLineLimit: Int = 1
    var cardHeight: CGFloat = 110
    var graphHeight: CGFloat = 60
    var showPercentageValue: Bool = true
    @Binding var isHidden: Bool
    var deltaText: String? = nil
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil
    var insightTarget: HardwareGraphFocusInsightTarget? = nil
    var focusSubtitle: String? = nil
    var focusAttributionEnabled: Bool = true
    var focusGPUContext: HardwareGraphFocusGPUContext? = nil
    var focusInlineMeters: [HardwareGraphFocusInlineMeter] = []
    var focusLinePanels: [HardwareGraphFocusLinePanelSnapshot] = []
    var focusScatterSnapshots: [HardwareGraphFocusScatterSnapshot] = []
    var focusDetailVisuals: [HardwareGraphFocusDetailVisual] = []
    var focusExtraStats: [HardwareGraphFocusStat] = []
    var focusExtraDetailLines: [String] = []
    var focusStateOverride: HardwareGraphFocusState? = nil
    var detailActionHandler: ((String) -> Void)? = nil

    init(
        title: String,
        current: Float?,
        history: @autoclosure @escaping () -> [Float],
        useMetalGraph: Bool = false,
        metalLineColor: SIMD4<Float> = SIMD4<Float>(0.25, 0.55, 1.0, 1.0),
        unitLabel: String? = nil,
        currentText: String? = nil,
        secondaryText: String? = nil,
        currentTextLineLimit: Int = 1,
        secondaryTextLineLimit: Int = 1,
        cardHeight: CGFloat = 110,
        graphHeight: CGFloat = 60,
        showPercentageValue: Bool = true,
        isHidden: Binding<Bool>,
        deltaText: String? = nil,
        onFocus: ((HardwareGraphFocusState) -> Void)? = nil,
        activeFocusID: String? = nil,
        onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil,
        insightTarget: HardwareGraphFocusInsightTarget? = nil,
        focusSubtitle: String? = nil,
        focusAttributionEnabled: Bool = true,
        focusGPUContext: HardwareGraphFocusGPUContext? = nil,
        focusInlineMeters: [HardwareGraphFocusInlineMeter] = [],
        focusLinePanels: [HardwareGraphFocusLinePanelSnapshot] = [],
        focusScatterSnapshots: [HardwareGraphFocusScatterSnapshot] = [],
        focusDetailVisuals: [HardwareGraphFocusDetailVisual] = [],
        focusExtraStats: [HardwareGraphFocusStat] = [],
        focusExtraDetailLines: [String] = [],
        focusStateOverride: HardwareGraphFocusState? = nil,
        detailActionHandler: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.current = current
        self.historyProvider = history
        self.useMetalGraph = useMetalGraph
        self.metalLineColor = metalLineColor
        self.unitLabel = unitLabel
        self.currentText = currentText
        self.secondaryText = secondaryText
        self.currentTextLineLimit = currentTextLineLimit
        self.secondaryTextLineLimit = secondaryTextLineLimit
        self.cardHeight = cardHeight
        self.graphHeight = graphHeight
        self.showPercentageValue = showPercentageValue
        self._isHidden = isHidden
        self.deltaText = deltaText
        self.onFocus = onFocus
        self.activeFocusID = activeFocusID
        self.onFocusedStateChange = onFocusedStateChange
        self.insightTarget = insightTarget
        self.focusSubtitle = focusSubtitle
        self.focusAttributionEnabled = focusAttributionEnabled
        self.focusGPUContext = focusGPUContext
        self.focusInlineMeters = focusInlineMeters
        self.focusLinePanels = focusLinePanels
        self.focusScatterSnapshots = focusScatterSnapshots
        self.focusDetailVisuals = focusDetailVisuals
        self.focusExtraStats = focusExtraStats
        self.focusExtraDetailLines = focusExtraDetailLines
        self.focusStateOverride = focusStateOverride
        self.detailActionHandler = detailActionHandler
    }

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 6 * appUIScale }
    private var scaledTitleBlockSpacing: CGFloat { 4 * appUIScale }
    private var scaledHeaderRowSpacing: CGFloat { 4 * appUIScale }
    private var scaledVerticalPadding: CGFloat { 12 * appUIScale }
    private var scaledHorizontalPadding: CGFloat { 10 * appUIScale }
    private var scaledGraphCornerRadius: CGFloat { 6 * appUIScale }
    private var scaledCardHeight: CGFloat { cardHeight * appUIScale }
    private var scaledGraphHeight: CGFloat { graphHeight * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var scaledUnitLeadingPadding: CGFloat { 2 * appUIScale }
    private var scaledHeaderSpacerMinLength: CGFloat { 4 * appUIScale }
    private var scaledCollapsedHeight: CGFloat { 38 * appUIScale }
    private var isCompactGridLayout: Bool { horizontalSizeClass == .compact }
    private static let maximumDisplayHistorySampleCount = 3_600

    private var displayHistory: [Float] {
        guard !isHidden else { return [] }
        let history = historyProvider()
        let clampedHistory = history.count > Self.maximumDisplayHistorySampleCount
            ? history.suffix(Self.maximumDisplayHistorySampleCount)
            : history[...]
        return clampedHistory.map(Self.sanitizedRatio)
    }

    private var displayCurrent: Float? {
        current.map(Self.sanitizedRatio)
    }

    private var focusAccentColor: Color {
        Color(
            red: Double(metalLineColor.x),
            green: Double(metalLineColor.y),
            blue: Double(metalLineColor.z)
        )
    }

    private var resolvedUsageCardID: String {
        let baseID = "usage-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        return focusGPUContext.map { "\(baseID)-\($0.deviceID)" } ?? baseID
    }

    private var floatingCardEntryKey: String? {
        guard let floatingMonitorSource else { return nil }
        return "\(floatingMonitorSource.key).graph.\(resolvedUsageCardID)"
    }

    private var floatingCardWindowTitle: String? {
        guard let floatingMonitorSource else { return nil }
        return "\(title) — \(floatingMonitorSource.displayName)"
    }

    private var floatingCardDefaultContentSize: CGSize {
        CGSize(
            width: max(340, graphHeight > 52 ? 420 : 380),
            height: max(146, cardHeight + 44)
        )
    }

    private var floatingCardMinimumContentSize: CGSize {
        CGSize(
            width: 300,
            height: max(138, cardHeight + 36)
        )
    }

    private var focusState: HardwareGraphFocusState? {
        if let focusStateOverride {
            return focusStateOverride
        }

        let history = displayHistory
        let current = displayCurrent
        let lineValues = history.map { Optional(Double($0)) }
        let observed = lineValues.compactMap { $0 }
        guard !observed.isEmpty || current != nil else { return nil }
        let baseFocusID = "usage-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let resolvedFocusID = focusGPUContext.map { "\(baseFocusID)-\($0.deviceID)" } ?? baseFocusID

        var stats: [HardwareGraphFocusStat] = []
        if let current {
            stats.append(.init(label: "Live", value: percentageString(Double(current)), tint: focusAccentColor))
        }
        if !observed.isEmpty {
            let average = observed.reduce(0, +) / Double(observed.count)
            stats.append(.init(label: "Window Avg", value: percentageString(average)))
            stats.append(.init(label: "Peak", value: percentageString(observed.max() ?? 0)))
            stats.append(.init(label: "Floor", value: percentageString(observed.min() ?? 0)))
            stats.append(.init(label: "Samples", value: "\(history.count)"))
        }
        if let deltaText, !deltaText.isEmpty {
            stats.append(.init(label: "Trend", value: deltaText, tint: deltaText.hasPrefix("↑") ? Color(red: 0.90, green: 0.40, blue: 0.40) : Color(red: 0.30, green: 0.75, blue: 0.45)))
        }

        let detailLines = [currentText, secondaryText]
            .compactMap { text -> String? in
                guard let text, !text.isEmpty else { return nil }
                return text
            }

        let subtitle = focusSubtitle ?? (unitLabel?.isEmpty == false ? unitLabel : "Focused view of the visible history window")

        return HardwareGraphFocusState(
            id: resolvedFocusID,
            title: title,
            subtitle: subtitle,
            accentColor: focusAccentColor,
            insightTarget: insightTarget,
            heatmapTarget: insightTarget.map(HardwareGraphFocusHeatmapTarget.init),
            attributionTarget: focusAttributionEnabled ? insightTarget.flatMap(HardwareGraphFocusAttributionTarget.init) : nil,
            gpuContext: focusGPUContext,
            visualization: .lineChart([
                HardwareGraphFocusSeries(
                    id: "primary",
                    label: title,
                    color: focusAccentColor,
                    values: lineValues
                )
            ]),
            inlineMeters: focusInlineMeters,
            linePanelSnapshots: focusLinePanels,
            scatterSnapshots: focusScatterSnapshots,
            detailVisuals: focusDetailVisuals,
            stats: stats + focusExtraStats,
            detailLines: detailLines + focusExtraDetailLines,
            detailActionHandler: detailActionHandler
        )
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        let history = displayHistory
        let current = displayCurrent
        if let focusStateOverride {
            hasher.combine(focusStateOverride.signatureHash)
            return hasher.finalize()
        }
        hasher.combine(title)
        hasher.combine(unitLabel ?? "")
        hasher.combine(focusSubtitle ?? "")
        hasher.combine(currentText ?? "")
        hasher.combine(secondaryText ?? "")
        hasher.combine(deltaText ?? "")
        hasher.combine(focusAttributionEnabled)
        if let focusGPUContext {
            hasher.combine(focusGPUContext.deviceID)
            hasher.combine(focusGPUContext.modelName)
        } else {
            hasher.combine("no-gpu-focus-context")
        }
        if let current {
            hasher.combine(Int((Double(current) * 1000).rounded()))
        } else {
            hasher.combine(-1)
        }
        for value in history {
            hasher.combine(Int((Double(value) * 1000).rounded()))
        }
        for snapshot in focusScatterSnapshots {
            hasher.combine(snapshot.signatureHash)
        }
        for meter in focusInlineMeters {
            hasher.combine(meter.signatureHash)
        }
        for panel in focusLinePanels {
            hasher.combine(panel.signatureHash)
        }
        for stat in focusExtraStats {
            hasher.combine(stat.label)
            hasher.combine(stat.value)
        }
        for line in focusExtraDetailLines {
            hasher.combine(line)
        }
        return hasher.finalize()
    }

    private var floatingCardSignature: Int {
        var hasher = Hasher()
        hasher.combine(focusRefreshSignature)
        hasher.combine(Int(cardHeight.rounded()))
        hasher.combine(Int(graphHeight.rounded()))
        hasher.combine(Int((Double(metalLineColor.x) * 1000).rounded()))
        hasher.combine(Int((Double(metalLineColor.y) * 1000).rounded()))
        hasher.combine(Int((Double(metalLineColor.z) * 1000).rounded()))
        hasher.combine(Int((Double(metalLineColor.w) * 1000).rounded()))
        return hasher.finalize()
    }

    var body: some View {
        let history = displayHistory
        let current = displayCurrent

        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: isHidden ? scaledCollapsedHeight : scaledCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: scaledHeaderSpacing) {
                    VStack(alignment: .leading, spacing: scaledTitleBlockSpacing) {
                        HStack(alignment: .firstTextBaseline, spacing: scaledHeaderRowSpacing) {
                            Text(title)
                                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .allowsTightening(true)

                            if let unitLabel {
                                Text(unitLabel)
                                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .allowsTightening(true)
                                    .truncationMode(.tail)
                                    .padding(.leading, scaledUnitLeadingPadding)
                                    .layoutPriority(1)
                            }

                            Spacer(minLength: scaledHeaderSpacerMinLength)

                            if let current, showPercentageValue {
                                let s = String(format: "%3.0f%%", current * 100)
                                if #available(macOS 12.0, *) {
                                    Text(s)
                                        .font(.system(size: scaledCaptionFontSize, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                } else {
                                    Text(s)
                                        .font(.system(size: scaledCaptionFontSize, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                            } else if unitLabel == nil {
                                Text("No data")
                                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            if let deltaText, !isHidden {
                                Text(deltaText)
                                    .font(.system(size: scaledCaption2FontSize - 1, weight: .medium))
                                    .foregroundColor(deltaText.hasPrefix("↑") ? Color(red: 0.9, green: 0.4, blue: 0.4) : Color(red: 0.3, green: 0.75, blue: 0.45))
                                    .padding(.horizontal, 4 * appUIScale)
                                    .padding(.vertical, 2 * appUIScale)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.white.opacity(0.07))
                                    )
                                    .transition(.opacity)
                            }

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isHidden.toggle()
                                }
                            } label: {
                                Image(systemName: isHidden ? "chevron.down" : "chevron.up")
                                    .font(.system(size: scaledCaption2FontSize))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        if !isHidden {
                            if let currentText {
                                if #available(macOS 12.0, *) {
                                    Text(currentText)
                                        .font(.system(size: scaledCaption2FontSize, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(currentTextLineLimit)
                                        .minimumScaleFactor(0.75)
                                        .allowsTightening(true)
                                        .truncationMode(.tail)
                                        .help(currentText)
                                } else {
                                    Text(currentText)
                                        .font(.system(size: scaledCaption2FontSize, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(currentTextLineLimit)
                                        .minimumScaleFactor(0.75)
                                        .allowsTightening(true)
                                        .truncationMode(.tail)
                                        .help(currentText)
                                }
                            }

                            if let secondaryText {
                                if #available(macOS 12.0, *) {
                                    Text(secondaryText)
                                        .font(.system(size: scaledCaption2FontSize, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .monospacedDigit()
                                        .lineLimit(secondaryTextLineLimit)
                                        .minimumScaleFactor(0.75)
                                        .allowsTightening(true)
                                        .truncationMode(.tail)
                                        .help(secondaryText)
                                } else {
                                    Text(secondaryText)
                                        .font(.system(size: scaledCaption2FontSize, weight: .regular, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(secondaryTextLineLimit)
                                        .minimumScaleFactor(0.75)
                                        .allowsTightening(true)
                                        .truncationMode(.tail)
                                        .help(secondaryText)
                                }
                            }
                        }
                    }

                    if !isHidden {
                        if useMetalGraph {
                            ZStack {
                                UsageHistoryGraphBackdrop(
                                    showGridlines: showGridlines,
                                    isCompact: isCompactGridLayout
                                )

                                MetalUsageGraphView(values: history, lineColor: metalLineColor)
                            }
                                .frame(height: scaledGraphHeight)
                                .clipShape(ThemeRoundedRectangle(cornerRadius: scaledGraphCornerRadius, style: .continuous))
                        } else {
                            ScrollingLineGraph(values: history)
                                .frame(height: scaledGraphHeight)
                                .clipShape(ThemeRoundedRectangle(cornerRadius: scaledGraphCornerRadius, style: .continuous))
                        }
                    }
                }
                .padding(.vertical, scaledVerticalPadding)
                .padding(.horizontal, scaledHorizontalPadding)
            )
            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .contextMenu {
                if floatingMonitorSource != nil {
                    Button("Add to Custom Stack") {
                        addToCustomStack()
                    }

                    Button("Open Floating Card") {
                        openFloatingCard()
                    }
                }
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard let onFocus, let focusState else { return }
                    onFocus(focusState)
                }
            )
            .onAppear {
                refreshFocusedStateIfNeeded()
                registerFloatingCardIfAvailable()
            }
            .onChange(of: floatingCardSignature) { _ in
                refreshFocusedStateIfNeeded()
                registerFloatingCardIfAvailable()
            }
    }

    private func percentageString(_ value: Double) -> String {
        String(format: "%3.0f%%", min(max(value, 0), 1) * 100)
    }

    private nonisolated static func sanitizedRatio(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }

    private func floatingCardEntry() -> FloatingCustomMonitorCardEntry? {
        guard let entryKey = floatingCardEntryKey,
              let windowTitle = floatingCardWindowTitle else { return nil }

        let card = UsageHistoryCard(
            title: title,
            current: displayCurrent,
            history: displayHistory,
            useMetalGraph: useMetalGraph,
            metalLineColor: metalLineColor,
            unitLabel: unitLabel,
            currentText: currentText,
            secondaryText: secondaryText,
            currentTextLineLimit: currentTextLineLimit,
            secondaryTextLineLimit: secondaryTextLineLimit,
            cardHeight: cardHeight,
            graphHeight: graphHeight,
            isHidden: .constant(false),
            deltaText: deltaText,
            onFocus: nil,
            activeFocusID: nil,
            onFocusedStateChange: nil,
            insightTarget: insightTarget,
            focusSubtitle: focusSubtitle,
            focusAttributionEnabled: focusAttributionEnabled,
            focusGPUContext: focusGPUContext,
            focusInlineMeters: focusInlineMeters,
            focusLinePanels: focusLinePanels,
            focusScatterSnapshots: focusScatterSnapshots,
            focusDetailVisuals: focusDetailVisuals,
            focusStateOverride: focusStateOverride
        )
        .environment(\.floatingMonitorSource, nil)

        return FloatingCustomMonitorCardEntry(
            key: entryKey,
            title: title,
            windowTitle: windowTitle,
            defaultContentSize: floatingCardDefaultContentSize,
            minimumContentSize: floatingCardMinimumContentSize,
            prefersFullWidthInCustomStack: false,
            content: AnyView(card)
        )
    }

    private func registerFloatingCardIfAvailable() {
        guard let entry = floatingCardEntry() else { return }
        FloatingCustomMonitorRegistry.shared.upsert(entry)
    }

    private func openFloatingCard() {
        guard let entry = floatingCardEntry() else { return }
        FloatingMonitorWindowController.shared.openCustomCard(entry)
    }

    private func addToCustomStack() {
        guard let source = floatingMonitorSource,
              let entry = floatingCardEntry() else { return }
        CustomMonitorStackWindowController.shared.addCustomCard(entry, source: source)
    }
}

private struct UsageHistoryGraphBackdrop: View {
    let showGridlines: Bool
    let isCompact: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            ZStack {
                if showGridlines {
                    usageHistoryGridlinesPath(width: width, height: height, isCompact: isCompact)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                }

                usageHistoryBaselinePath(width: width, height: height)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

struct ScrollingLineGraph: View {
    @Environment(\.graphShowGridlines) private var showGridlines
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let values: [Float]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                UsageHistoryGraphBackdrop(
                    showGridlines: showGridlines,
                    isCompact: horizontalSizeClass == .compact
                )

                if values.count >= 2 {
                    Path { p in
                        let n = values.count
                        let dx = w / CGFloat(max(n - 1, 1))
                        for i in 0..<n {
                            let v = CGFloat(min(max(values[i], 0), 1))
                            let x = CGFloat(i) * dx
                            let y = (1 - v) * h
                            if i == 0 {
                                p.move(to: CGPoint(x: x, y: y))
                            } else {
                                p.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.white.opacity(0.65), lineWidth: 1.25)

                    Path { p in
                        let n = values.count
                        let dx = w / CGFloat(max(n - 1, 1))
                        p.move(to: CGPoint(x: 0, y: h))
                        for i in 0..<n {
                            let v = CGFloat(min(max(values[i], 0), 1))
                            let x = CGFloat(i) * dx
                            let y = (1 - v) * h
                            p.addLine(to: CGPoint(x: x, y: y))
                        }
                        p.addLine(to: CGPoint(x: w, y: h))
                        p.closeSubpath()
                    }
                    .fill(Color.white.opacity(0.08))
                }
            }
        }
    }
}

private func usageHistoryGridlinesPath(width: CGFloat, height: CGFloat, isCompact: Bool) -> Path {
    var path = Path()
    let horizontalGridlineCount = 4
    let verticalGridlineCount = isCompact ? 15 : 30

    for i in 1...horizontalGridlineCount {
        let y = (CGFloat(i) / CGFloat(horizontalGridlineCount + 1)) * height
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: width, y: y))
    }

    for i in 1...verticalGridlineCount {
        let x = (CGFloat(i) / CGFloat(verticalGridlineCount + 1)) * width
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: height))
    }

    return path
}

private func usageHistoryBaselinePath(width: CGFloat, height: CGFloat) -> Path {
    Path { path in
        path.move(to: CGPoint(x: 0, y: height - 1))
        path.addLine(to: CGPoint(x: width, y: height - 1))
    }
}

// MARK: - UI Helpers

struct SectionHeader: View {
    @Environment(\.appUIScale) private var appUIScale
    let title: String

    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledTopPadding: CGFloat { 8 * appUIScale }

    var body: some View {
        Text(title)
            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
            .padding(.top, scaledTopPadding)
    }
}

struct CollapsibleGraphSection<Content: View>: View {
    @Environment(\.appUIScale) private var appUIScale
    let title: String
    let subtitle: String?
    @Binding var isCollapsed: Bool
    @ViewBuilder let content: () -> Content

    private var scaledCornerRadius: CGFloat { 18 * appUIScale }
    private var scaledPadding: CGFloat { 14 * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 2 * appUIScale }
    private var scaledContentSpacing: CGFloat { 14 * appUIScale }
    private var scaledTitleSize: CGFloat { 13 * appUIScale }
    private var scaledSubtitleSize: CGFloat { 11 * appUIScale }
    private var scaledToggleSize: CGFloat { 10.5 * appUIScale }
    private var scaledTogglePaddingX: CGFloat { 9 * appUIScale }
    private var scaledTogglePaddingY: CGFloat { 5 * appUIScale }

    var body: some View {
        VStack(alignment: .leading, spacing: scaledContentSpacing) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10 * appUIScale) {
                    VStack(alignment: .leading, spacing: scaledHeaderSpacing) {
                        Text(title)
                            .font(.system(size: scaledTitleSize, weight: .semibold))
                            .foregroundColor(.primary)

                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: scaledSubtitleSize, weight: .regular))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 12 * appUIScale)

                    HStack(spacing: 5 * appUIScale) {
                        Text(isCollapsed ? "Show" : "Hide")
                            .font(.system(size: scaledToggleSize, weight: .semibold))
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: scaledToggleSize, weight: .bold))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, scaledTogglePaddingX)
                    .padding(.vertical, scaledTogglePaddingY)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(scaledPadding)
        .background(
            ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous).themed(fill: Color.black.opacity(0.08), stroke: Color.white.opacity(0.12))
        )
    }
}

struct PlaceholderCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let text: String

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardHeight: CGFloat { 80 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                Text(text)
                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                    .foregroundColor(.secondary)
            )
    }
}

struct PressureMiniCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let label: String
    let value: Float

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardHeight: CGFloat { 70 * appUIScale }
    private var scaledStackSpacing: CGFloat { 8 * appUIScale }
    private var scaledMeterHeight: CGFloat { 10 * appUIScale }
    private var scaledMeterCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: scaledStackSpacing) {
                    HStack {
                        Text("Memory Pressure")
                            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))

                        Spacer()

                        if #available(macOS 12.0, *) {
                            Text(label)
                                .font(.system(size: scaledCaptionFontSize, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        } else {
                            Text(label)
                                .font(.system(size: scaledCaptionFontSize, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }

                    MetalPressureMeterView(value: value)
                        .frame(height: scaledMeterHeight)
                        .clipShape(ThemeRoundedRectangle(cornerRadius: scaledMeterCornerRadius, style: .continuous))

                    Text("Estimated")
                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .padding(scaledPadding)
            )
    }
}

// MARK: - GPU Memory Pressure Bar

struct GPUMemoryPressureBar: View {
    @Environment(\.appUIScale) private var appUIScale
    let usedMB: Double?
    let ceilingMB: Double?
    let allocatedMB: Double?
    var isUnifiedCeilingEstimate: Bool = false

    private var displayedPressureMB: Double? {
        if isUnifiedCeilingEstimate {
            return allocatedMB ?? usedMB
        }
        return usedMB ?? allocatedMB
    }

    private var ratio: Double {
        guard let displayedPressureMB, let ceilingMB, ceilingMB > 0 else { return 0 }
        return min(displayedPressureMB / ceilingMB, 1.0)
    }

    private var fillGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color(red: 0.40, green: 0.06, blue: 0.08), location: 0.0),
                .init(color: Color(red: 0.40, green: 0.06, blue: 0.08), location: 0.60),
                .init(color: Color(red: 0.66, green: 0.16, blue: 0.10), location: 0.70),
                .init(color: Color(red: 0.92, green: 0.48, blue: 0.10), location: 0.85),
                .init(color: Color(red: 0.86, green: 0.12, blue: 0.12), location: 1.0)
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var scaledFontSize: CGFloat { 10 * appUIScale }
    private var scaledBarHeight: CGFloat { 10 * appUIScale }

    private var titleText: String {
        isUnifiedCeilingEstimate ? "GPU Mem" : "VRAM"
    }

    private func formatMemory(_ megabytes: Double) -> String {
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024.0)
        }
        return String(format: "%.0f MB", megabytes)
    }

    var body: some View {
        guard usedMB != nil || allocatedMB != nil else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 3 * appUIScale) {
                HStack(spacing: 4 * appUIScale) {
                    Text(titleText)
                        .font(.system(size: scaledFontSize, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let displayedPressureMB, let ceilingMB {
                        let prefix = isUnifiedCeilingEstimate && allocatedMB != nil ? "Alloc " : ""
                        let suffix = isUnifiedCeilingEstimate ? " est." : ""
                        Text("\(prefix)\(formatMemory(displayedPressureMB)) / \(formatMemory(ceilingMB))\(suffix)")
                            .font(.system(size: scaledFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                    } else if let alloc = allocatedMB {
                        Text("Alloc \(formatMemory(alloc))")
                            .font(.system(size: scaledFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                    } else if let used = usedMB {
                        Text(formatMemory(used))
                            .font(.system(size: scaledFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                        if ratio > 0 {
                            Rectangle()
                                .fill(fillGradient)
                                .frame(width: geo.size.width)
                                .mask(
                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .frame(width: geo.size.width * CGFloat(ratio))
                                        Spacer(minLength: 0)
                                    }
                                )
                        }
                    }
                }
                .frame(height: scaledBarHeight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }
}

struct PingLatencyMeterBar: View {
    @Environment(\.appUIScale) private var appUIScale
    let currentLatency: Double?
    let maxLatency: Double = 100.0

    private var ratio: Double {
        guard let currentLatency, maxLatency > 0 else { return 0 }
        return min(currentLatency / maxLatency, 1.0)
    }

    private var fillGradient: LinearGradient {
        // Gradient spans across the full width of the bar.
        // The fill shape will clip this full-width gradient to the current value.
        // Thresholds based on maxLatency = 100ms:
        // 0-20ms (0.0-0.2): dark green
        // 20-50ms (0.2-0.5): light green
        // 50-70ms (0.5-0.7): orange
        // 70-90ms (0.7-0.9): light red
        // 90-100ms+ (0.9-1.0): dark red
        let darkGreen  = Color(red: 0.10, green: 0.55, blue: 0.22)
        let lightGreen = Color(red: 0.42, green: 0.85, blue: 0.45)
        let orange     = Color(red: 0.96, green: 0.58, blue: 0.12)
        let lightRed   = Color(red: 0.90, green: 0.22, blue: 0.18)
        let darkRed    = Color(red: 0.55, green: 0.08, blue: 0.06)

        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: darkGreen,  location: 0.00),
                .init(color: darkGreen,  location: 0.20),
                .init(color: lightGreen, location: 0.50),
                .init(color: orange,     location: 0.70),
                .init(color: lightRed,   location: 0.90),
                .init(color: darkRed,    location: 1.00)
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var scaledFontSize: CGFloat { 10 * appUIScale }
    private var scaledBarHeight: CGFloat { 10 * appUIScale }

    private var textColor: Color {
        guard let currentLatency else { return .secondary }
        return currentLatency >= 70 ? .red : .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * appUIScale) {
            HStack(spacing: 4 * appUIScale) {
                Text("Ping")
                    .font(.system(size: scaledFontSize, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let currentLatency {
                    Text(String(format: "%.1f ms", currentLatency))
                        .font(.system(size: scaledFontSize, weight: .regular))
                        .foregroundColor(textColor)
                } else {
                    Text("— ms")
                        .font(.system(size: scaledFontSize, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.4))
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))

                    if ratio > 0 {
                        Rectangle()
                            .fill(fillGradient)
                            // Ensure the gradient maps to the entire bar width
                            .frame(width: geometry.size.width)
                            // Width is proportion of full bar instead of scaleEffect so the gradient isn't compressed
                            .frame(width: geometry.size.width * CGFloat(ratio), alignment: .leading)
                            .clipped()
                    }
                }
            }
            .frame(height: scaledBarHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PingLatencyFloatingCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let currentLatency: Double?
    let packetLossRatio: Double?
    let targetLabel: String
    let intervalText: String

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledSpacing: CGFloat { 8 * appUIScale }
    private var scaledColumnSpacing: CGFloat { 10 * appUIScale }
    private var scaledLabelFontSize: CGFloat { 10 * appUIScale }
    private var scaledValueFontSize: CGFloat { 12 * appUIScale }
    private var scaledMinimumHeight: CGFloat { 132 * appUIScale }

    private var latencyText: String {
        guard let currentLatency else { return "—" }
        if currentLatency >= 100 {
            return String(format: "%.0f ms", currentLatency)
        }
        return String(format: "%.1f ms", currentLatency)
    }

    private var packetLossText: String {
        guard let packetLossRatio else { return "—" }
        return String(format: "%.1f%%", packetLossRatio * 100.0)
    }

    private func metricBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * appUIScale) {
            Text(title)
                .font(.system(size: scaledLabelFontSize, weight: .medium))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: scaledValueFontSize, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .overlay(
                VStack(alignment: .leading, spacing: scaledSpacing) {
                    PingLatencyMeterBar(currentLatency: currentLatency)

                    HStack(alignment: .top, spacing: scaledColumnSpacing) {
                        metricBlock(title: "Target", value: targetLabel)
                        metricBlock(title: "Interval", value: intervalText)
                    }

                    HStack(alignment: .top, spacing: scaledColumnSpacing) {
                        metricBlock(title: "Latency", value: latencyText)
                        metricBlock(title: "Packet Loss", value: packetLossText)
                    }
                }
                .padding(scaledPadding),
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, minHeight: scaledMinimumHeight, alignment: .topLeading)
    }
}

struct GPUMemoryPressureFloatingCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let usedMB: Double?
    let ceilingMB: Double?
    let allocatedMB: Double?
    var isUnifiedCeilingEstimate: Bool = false
    var detailText: String? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledSpacing: CGFloat { 8 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var scaledMinimumHeight: CGFloat {
        detailText?.isEmpty == false ? 96 * appUIScale : 76 * appUIScale
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .overlay(
                VStack(alignment: .leading, spacing: scaledSpacing) {
                    GPUMemoryPressureBar(
                        usedMB: usedMB,
                        ceilingMB: ceilingMB,
                        allocatedMB: allocatedMB,
                        isUnifiedCeilingEstimate: isUnifiedCeilingEstimate
                    )

                    if let detailText, !detailText.isEmpty {
                        Text(detailText)
                            .font(.system(size: scaledCaption2FontSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(scaledPadding),
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, minHeight: scaledMinimumHeight, alignment: .topLeading)
    }
}

struct EnergyUsageCard: View {
    let current: Float?
    let history: [Float]
    let cpu: Float?
    let gpu: Float?
    let ram: Float?
    let cpuPowerText: String
    let gpuPowerText: String
    let anePowerText: String
    let combinedPowerText: String
    let peakCombinedPowerText: String
    @Binding var isHidden: Bool
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil
    var focusScatterSnapshots: [HardwareGraphFocusScatterSnapshot] = []

    private var energyBandLabel: String? {
        guard let current else { return nil }
        switch current {
        case ..<0.20: return "Very Low"
        case ..<0.40: return "Low"
        case ..<0.65: return "Moderate"
        case ..<0.85: return "High"
        default: return "Very High"
        }
    }

    private var usageDetailText: String? {
        let parts: [String?] = [
            cpu.map { String(format: "CPU %3.0f%%", $0 * 100) },
            gpu.map { String(format: "GPU %3.0f%%", $0 * 100) },
            ram.map { String(format: "RAM %3.0f%%", $0 * 100) }
        ]

        let joined = parts.compactMap { $0 }.joined(separator: "  ·  ")
        return joined.isEmpty ? nil : joined
    }

    private var powerDetailText: String? {
        let parts: [String?] = [
            cpuPowerText == "—" ? nil : "CPU \(cpuPowerText)",
            gpuPowerText == "—" ? nil : "GPU \(gpuPowerText)",
            anePowerText == "—" ? nil : "ANE \(anePowerText)",
            combinedPowerText == "—" ? nil : "Combined \(combinedPowerText)",
            peakCombinedPowerText == "—" ? nil : "Peak \(peakCombinedPowerText)"
        ]

        let joined = parts.compactMap { $0 }.joined(separator: "  ·  ")
        return joined.isEmpty ? nil : joined
    }

    var body: some View {
        UsageHistoryCard(
            title: "Energy Usage",
            current: current,
            history: history,
            useMetalGraph: true,
            metalLineColor: SIMD4<Float>(1.0, 0.60, 0.00, 1.0),
            unitLabel: energyBandLabel,
            currentText: usageDetailText,
            secondaryText: powerDetailText,
            currentTextLineLimit: 1,
            secondaryTextLineLimit: 1,
            cardHeight: 122,
            graphHeight: 60,
            isHidden: $isHidden,
            onFocus: onFocus,
            activeFocusID: activeFocusID,
            onFocusedStateChange: onFocusedStateChange,
            insightTarget: .power,
            focusScatterSnapshots: focusScatterSnapshots
        )
    }
}

struct GraphSettingsCard: View {
    @Environment(\.appUIScale) private var appUIScale
    @Binding var timeWindowSeconds: Int
    @Binding var displayIntervalSeconds: Int
    @AppStorage("graph.showGridlines") private var graphShowGridlines: Bool = true

    private let timeWindowPresets: [Int] = [
        10, 30, 60, 300, 900, 1800, 3600,
        21_600, 43_200, 86_400, 172_800, 432_000
    ]

    private let sampleIntervalPresets: [Int] = [
        1, 2, 5, 10, 30, 60, 300, 900, 1800, 3600
    ]

    private var estimatedBuckets: Int {
        max(1, Int(ceil(Double(timeWindowSeconds) / Double(max(displayIntervalSeconds, 1)))))
    }

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardHeight: CGFloat { 148 * appUIScale }
    private var scaledStackSpacing: CGFloat { 10 * appUIScale }
    private var scaledSectionSpacing: CGFloat { 8 * appUIScale }
    private var scaledPadding: CGFloat { 10 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var scaledHeaderSpacerMinLength: CGFloat { 8 * appUIScale }
    private var scaledPickerWidth: CGFloat { 148 * appUIScale }
    private var scaledBadgeHorizontalPadding: CGFloat { 8 * appUIScale }
    private var scaledBadgeVerticalPadding: CGFloat { 4 * appUIScale }

    private var pickerControlSize: ControlSize {
        if appUIScale <= 0.8 {
            return .mini
        } else {
            return .small
        }
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: scaledStackSpacing) {
                    HStack(alignment: .center, spacing: scaledSectionSpacing) {
                        Text("Graph Settings")
                            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))

                        Spacer(minLength: scaledHeaderSpacerMinLength)

                        Text("\(estimatedBuckets) buckets")
                            .font(.system(size: scaledCaption2FontSize, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, scaledBadgeHorizontalPadding)
                            .padding(.vertical, scaledBadgeVerticalPadding)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }

                    VStack(alignment: .leading, spacing: scaledSectionSpacing) {
                        settingRow(title: "Time Window") {
                            Picker("Time Window", selection: $timeWindowSeconds) {
                                ForEach(timeWindowPresets, id: \.self) { value in
                                    Text(formatDuration(value)).tag(value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(pickerControlSize)
                            .scaleEffect(appUIScale, anchor: .trailing)
                            .frame(width: scaledPickerWidth, alignment: .trailing)
                        }

                        settingRow(title: "Display Interval") {
                            Picker("Display Interval", selection: $displayIntervalSeconds) {
                                ForEach(sampleIntervalPresets, id: \.self) { value in
                                    Text(formatSampleInterval(value)).tag(value)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(pickerControlSize)
                            .scaleEffect(appUIScale, anchor: .trailing)
                            .frame(width: scaledPickerWidth, alignment: .trailing)
                        }

                        settingRow(title: "Gridlines") {
                            Toggle("", isOn: .init(
                                get: { graphShowGridlines },
                                set: { graphShowGridlines = $0 }
                            ))
                            .labelsHidden()
                            .scaleEffect(appUIScale, anchor: .trailing)
                        }
                    }

                    Text("Display interval changes density only; collection cadence is handled separately.")
                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(scaledPadding)
            )
    }

    @ViewBuilder
    private func settingRow<Control: View>(
        title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: scaledSectionSpacing) {
            Text(title)
                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                .foregroundColor(.secondary)

            Spacer(minLength: scaledHeaderSpacerMinLength)

            control()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        let mins = (s % 3_600) / 60
        let secs = s % 60
        return String(format: "%02d:%02d:%02d:%02d", days, hours, mins, secs)
    }

    private func formatSampleInterval(_ seconds: Int) -> String {
        switch seconds {
        case 3600:
            return "1 sample / 01:00:00"
        case 60...3599:
            let mins = seconds / 60
            let secs = seconds % 60
            return String(format: "1 sample / %02d:%02d", mins, secs)
        default:
            return "1 sample / \(seconds)s"
        }
    }
}

// MARK: - Metal Render Helpers

/// Returns true if the average per-element difference between two Float arrays exceeds `threshold`.
/// Arrays with different counts always count as a significant change.
private func metalArrayChangedSignificantly(_ new: [Float], _ last: [Float], threshold: Float) -> Bool {
    guard new.count == last.count else { return true }
    guard !new.isEmpty else { return false }
    var totalDiff: Float = 0
    for i in new.indices {
        totalDiff += abs(new[i] - last[i])
    }
    return totalDiff / Float(new.count) > threshold
}
