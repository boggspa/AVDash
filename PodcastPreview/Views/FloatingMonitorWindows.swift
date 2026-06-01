import SwiftUI
import AppKit
import Combine
import PodcastPreviewCore
import PodcastPreviewShared

private let floatingMonitorFallbackAnchorDate = Date()

enum FloatingMonitorCardSource {
    case local
    case remote(RemoteMachineConnection)

    var key: String {
        switch self {
        case .local:
            return "local"
        case .remote(let connection):
            return "remote-\(connection.id)"
        }
    }

    var displayName: String {
        switch self {
        case .local:
            return "This Mac"
        case .remote(let connection):
            return connection.identity?.displayName ?? connection.machineName
        }
    }
}

private struct FloatingMonitorSourceEnvironmentKey: EnvironmentKey {
    static let defaultValue: FloatingMonitorCardSource? = nil
}

extension EnvironmentValues {
    var floatingMonitorSource: FloatingMonitorCardSource? {
        get { self[FloatingMonitorSourceEnvironmentKey.self] }
        set { self[FloatingMonitorSourceEnvironmentKey.self] = newValue }
    }
}

enum FloatingMonitorCardKind: String, Codable {
    case hardwareInsights
    case periodicAverages
    case activityHeatmap
    case topApps
    case cpuCores
    case gpuUnit
    case memoryUnit
    case networkStats
    case stereoOutput
    case spectrum
    case remoteMachineTile

    var title: String {
        switch self {
        case .hardwareInsights:
            return "Hardware Insights"
        case .periodicAverages:
            return "Periodic Averages"
        case .activityHeatmap:
            return "Activity Heatmap"
        case .topApps:
            return "Top Apps"
        case .cpuCores:
            return "CPU Cores"
        case .gpuUnit:
            return "GPU"
        case .memoryUnit:
            return "Memory"
        case .networkStats:
            return "Network Stats"
        case .stereoOutput:
            return "Stereo Output"
        case .spectrum:
            return "Spectrum"
        case .remoteMachineTile:
            return "Connected Mac"
        }
    }

    var defaultContentSize: CGSize {
        switch self {
        case .hardwareInsights:
            return CGSize(width: 332, height: 792)
        case .periodicAverages:
            return CGSize(width: 820, height: 332)
        case .activityHeatmap:
            return CGSize(width: 820, height: 470)
        case .topApps:
            return CGSize(width: 336, height: 700)
        case .cpuCores:
            return CGSize(width: 336, height: 420)
        case .networkStats:
            return CGSize(width: 336, height: 320)
        case .stereoOutput:
            return CGSize(width: 336, height: 260)
        case .spectrum:
            return CGSize(width: 336, height: 280)
        case .remoteMachineTile:
            return CGSize(width: 382, height: 190)
        case .gpuUnit:
            return CGSize(width: 336, height: 400)
        case .memoryUnit:
            return CGSize(width: 336, height: 400)
        }
    }

    var minimumContentSize: CGSize {
        switch self {
        case .hardwareInsights:
            return CGSize(width: 300, height: 620)
        case .periodicAverages:
            return CGSize(width: 680, height: 280)
        case .activityHeatmap:
            return CGSize(width: 680, height: 360)
        case .topApps:
            return CGSize(width: 300, height: 520)
        case .cpuCores:
            return CGSize(width: 300, height: 260)
        case .networkStats:
            return CGSize(width: 300, height: 280)
        case .stereoOutput:
            return CGSize(width: 300, height: 220)
        case .spectrum:
            return CGSize(width: 300, height: 240)
        case .remoteMachineTile:
            return CGSize(width: 340, height: 160)
        case .gpuUnit:
            return CGSize(width: 300, height: 300)
        case .memoryUnit:
            return CGSize(width: 300, height: 300)
        }
    }

    var prefersFullWidthInCustomStack: Bool {
        switch self {
        case .periodicAverages, .activityHeatmap:
            return true
        default:
            return false
        }
    }

    func windowTitle(for source: FloatingMonitorCardSource) -> String {
        switch self {
        case .remoteMachineTile:
            return source.displayName
        default:
            return "\(title) — \(source.displayName)"
        }
    }
}

enum CustomMonitorStackLayoutMode: String, CaseIterable, Identifiable, Codable {
    case stack
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stack:
            return "Stack"
        case .compact:
            return "Compact"
        }
    }
}

enum CustomMonitorStackItem: Hashable, Codable {
    case builtIn(FloatingMonitorCardKind)
    case custom(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case builtInKind
        case customKey
    }

    private enum PersistedKind: String, Codable {
        case builtIn
        case custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedKind = try container.decode(PersistedKind.self, forKey: .kind)
        switch persistedKind {
        case .builtIn:
            self = .builtIn(try container.decode(FloatingMonitorCardKind.self, forKey: .builtInKind))
        case .custom:
            self = .custom(try container.decode(String.self, forKey: .customKey))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn(let kind):
            try container.encode(PersistedKind.builtIn, forKey: .kind)
            try container.encode(kind, forKey: .builtInKind)
        case .custom(let entryKey):
            try container.encode(PersistedKind.custom, forKey: .kind)
            try container.encode(entryKey, forKey: .customKey)
        }
    }
}

@MainActor
final class CustomMonitorStackStore: ObservableObject {
    struct StackState: Codable, Equatable {
        var items: [CustomMonitorStackItem] = []
        var layoutMode: CustomMonitorStackLayoutMode = .stack
    }

    struct SavedStackPreset: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var state: StackState
        var updatedAt: Date
    }

    private struct PersistedState: Codable {
        var states: [String: StackState] = [:]
        var savedPresetsBySource: [String: [SavedStackPreset]] = [:]
    }

    static let shared = CustomMonitorStackStore()
    private static let defaultsKey = "floatingMonitor.customStacks.v1"

    private let userDefaults: UserDefaults
    @Published private var states: [String: StackState]
    @Published private var savedPresetsBySource: [String: [SavedStackPreset]]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.defaultsKey),
           let persisted = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.states = persisted.states
            self.savedPresetsBySource = persisted.savedPresetsBySource
        } else {
            self.states = [:]
            self.savedPresetsBySource = [:]
        }
    }

    func state(for source: FloatingMonitorCardSource) -> StackState {
        states[source.key] ?? StackState()
    }

    func savedPresets(for source: FloatingMonitorCardSource) -> [SavedStackPreset] {
        (savedPresetsBySource[source.key] ?? [])
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    func add(_ kind: FloatingMonitorCardKind, to source: FloatingMonitorCardSource) {
        var state = states[source.key] ?? StackState()
        let item = CustomMonitorStackItem.builtIn(kind)
        guard state.items.contains(item) == false else {
            states[source.key] = state
            persist()
            return
        }
        state.items.append(item)
        states[source.key] = state
        persist()
    }

    func addCustom(_ entryKey: String, to source: FloatingMonitorCardSource) {
        var state = states[source.key] ?? StackState()
        let item = CustomMonitorStackItem.custom(entryKey)
        guard state.items.contains(item) == false else {
            states[source.key] = state
            persist()
            return
        }
        state.items.append(item)
        states[source.key] = state
        persist()
    }

    func remove(_ kind: FloatingMonitorCardKind, from source: FloatingMonitorCardSource) {
        var state = states[source.key] ?? StackState()
        state.items.removeAll { $0 == .builtIn(kind) }
        states[source.key] = state
        persist()
    }

    func removeCustom(_ entryKey: String, from source: FloatingMonitorCardSource) {
        var state = states[source.key] ?? StackState()
        state.items.removeAll { $0 == .custom(entryKey) }
        states[source.key] = state
        persist()
    }

    func move(_ item: CustomMonitorStackItem, in source: FloatingMonitorCardSource, offset: Int) {
        var state = states[source.key] ?? StackState()
        guard let currentIndex = state.items.firstIndex(of: item) else { return }
        let targetIndex = max(0, min(state.items.count - 1, currentIndex + offset))
        guard targetIndex != currentIndex else { return }
        let item = state.items.remove(at: currentIndex)
        state.items.insert(item, at: targetIndex)
        states[source.key] = state
        persist()
    }

    func move(_ kind: FloatingMonitorCardKind, in source: FloatingMonitorCardSource, offset: Int) {
        move(.builtIn(kind), in: source, offset: offset)
    }

    func setLayoutMode(_ layoutMode: CustomMonitorStackLayoutMode, for source: FloatingMonitorCardSource) {
        var state = states[source.key] ?? StackState()
        state.layoutMode = layoutMode
        states[source.key] = state
        persist()
    }

    func contains(_ kind: FloatingMonitorCardKind, in source: FloatingMonitorCardSource) -> Bool {
        state(for: source).items.contains(.builtIn(kind))
    }

    func clear(source: FloatingMonitorCardSource) {
        states[source.key] = StackState()
        persist()
    }

    @discardableResult
    func saveCurrentState(named name: String, for source: FloatingMonitorCardSource) -> SavedStackPreset? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return nil }

        let sourceKey = source.key
        let state = states[sourceKey] ?? StackState()
        var presets = savedPresetsBySource[sourceKey] ?? []
        let now = Date()

        if let existingIndex = presets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
            presets[existingIndex].name = trimmedName
            presets[existingIndex].state = state
            presets[existingIndex].updatedAt = now
            savedPresetsBySource[sourceKey] = presets
            persist()
            return presets[existingIndex]
        }

        let preset = SavedStackPreset(
            id: UUID(),
            name: trimmedName,
            state: state,
            updatedAt: now
        )
        presets.append(preset)
        savedPresetsBySource[sourceKey] = presets
        persist()
        return preset
    }

    @discardableResult
    func applySavedPreset(_ presetID: SavedStackPreset.ID, to source: FloatingMonitorCardSource) -> SavedStackPreset? {
        let sourceKey = source.key
        guard let preset = (savedPresetsBySource[sourceKey] ?? []).first(where: { $0.id == presetID }) else {
            return nil
        }
        states[sourceKey] = preset.state
        persist()
        return preset
    }

    private func persist() {
        let persisted = PersistedState(
            states: states,
            savedPresetsBySource: savedPresetsBySource
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}

struct FloatingCustomMonitorCardEntry {
    let key: String
    let title: String
    let windowTitle: String
    let defaultContentSize: CGSize
    let minimumContentSize: CGSize
    let prefersFullWidthInCustomStack: Bool
    let startsPinned: Bool
    let content: AnyView

    init(
        key: String,
        title: String,
        windowTitle: String,
        defaultContentSize: CGSize,
        minimumContentSize: CGSize,
        prefersFullWidthInCustomStack: Bool,
        startsPinned: Bool = true,
        content: AnyView
    ) {
        self.key = key
        self.title = title
        self.windowTitle = windowTitle
        self.defaultContentSize = defaultContentSize
        self.minimumContentSize = minimumContentSize
        self.prefersFullWidthInCustomStack = prefersFullWidthInCustomStack
        self.startsPinned = startsPinned
        self.content = content
    }
}

@MainActor
final class FloatingWindowChromeModel: ObservableObject {
    @Published private(set) var isPinned: Bool
    private weak var panel: NSPanel?

    init(isPinned: Bool = true) {
        self.isPinned = isPinned
    }

    func attach(panel: NSPanel) {
        self.panel = panel
        applyPinnedState()
    }

    func togglePinned() {
        isPinned.toggle()
        applyPinnedState()
    }

    func closeWindow() {
        panel?.close()
    }

    private func applyPinnedState() {
        guard let panel else { return }
        panel.isFloatingPanel = isPinned
        panel.level = isPinned ? .floating : .normal
    }
}

@MainActor
final class FloatingCustomMonitorRegistry: ObservableObject {
    static let shared = FloatingCustomMonitorRegistry()

    @Published private(set) var revision: Int = 0
    private var entries: [String: FloatingCustomMonitorCardEntry] = [:]

    func upsert(_ entry: FloatingCustomMonitorCardEntry) {
        entries[entry.key] = entry
        revision &+= 1
    }

    func entry(for key: String) -> FloatingCustomMonitorCardEntry? {
        entries[key]
    }
}

@MainActor
final class FloatingMonitorWindowController: NSObject, NSWindowDelegate {
    static let shared = FloatingMonitorWindowController()

    private var windows: [String: NSPanel] = [:]

    func openCard(_ kind: FloatingMonitorCardKind, source: FloatingMonitorCardSource) {
        let windowKey = "\(source.key).\(kind.rawValue)"
        if let existing = windows[windowKey] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = makePanel(kind: kind, source: source, windowKey: windowKey)
        windows[windowKey] = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let key = panel.identifier?.rawValue else { return }
        windows.removeValue(forKey: key)
    }

    private func makePanel(
        kind: FloatingMonitorCardKind,
        source: FloatingMonitorCardSource,
        windowKey: String
    ) -> NSPanel {
        let contentSize = kind.defaultContentSize
        let chromeModel = FloatingWindowChromeModel()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.identifier = NSUserInterfaceItemIdentifier(windowKey)
        panel.delegate = self
        panel.title = kind.windowTitle(for: source)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentMinSize = kind.minimumContentSize
        panel.setContentSize(contentSize)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = WindowScaledRootView(
            configuration: .floatingPanel(referenceSize: contentSize)
        ) {
            FloatingMonitorWindowRoot(kind: kind, source: source)
                .environmentObject(chromeModel)
        }
        .applyThemeEnvironment()

        panel.contentViewController = NSHostingController(rootView: rootView)
        chromeModel.attach(panel: panel)

        if let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            let topLeft = NSPoint(
                x: anchorWindow.frame.minX + 48,
                y: anchorWindow.frame.maxY - 48
            )
            panel.setFrameTopLeftPoint(topLeft)
        } else {
            panel.center()
        }

        return panel
    }

    func openCustomCard(_ entry: FloatingCustomMonitorCardEntry) {
        FloatingCustomMonitorRegistry.shared.upsert(entry)

        if let existing = windows[entry.key] {
            existing.title = entry.windowTitle
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let chromeModel = FloatingWindowChromeModel(isPinned: entry.startsPinned)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: entry.defaultContentSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.identifier = NSUserInterfaceItemIdentifier(entry.key)
        panel.delegate = self
        panel.title = entry.windowTitle
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentMinSize = entry.minimumContentSize
        panel.setContentSize(entry.defaultContentSize)

        let rootView = WindowScaledRootView(
            configuration: .floatingPanel(referenceSize: entry.defaultContentSize)
        ) {
            FloatingCustomMonitorWindowRoot(entryKey: entry.key)
                .environmentObject(chromeModel)
        }
        .applyThemeEnvironment()

        panel.contentViewController = NSHostingController(rootView: rootView)
        chromeModel.attach(panel: panel)

        if let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            let topLeft = NSPoint(
                x: anchorWindow.frame.minX + 48,
                y: anchorWindow.frame.maxY - 48
            )
            panel.setFrameTopLeftPoint(topLeft)
        } else {
            panel.center()
        }

        windows[entry.key] = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class CustomMonitorStackWindowController: NSObject, NSWindowDelegate {
    static let shared = CustomMonitorStackWindowController()

    private var windows: [String: NSPanel] = [:]

    func addToStack(_ kind: FloatingMonitorCardKind, source: FloatingMonitorCardSource) {
        CustomMonitorStackStore.shared.add(kind, to: source)
        openStack(for: source)
    }

    func openStack(for source: FloatingMonitorCardSource) {
        let windowKey = "\(source.key).custom-stack"
        if let existing = windows[windowKey] {
            existing.title = "Custom Stack — \(source.displayName)"
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentSize = CGSize(width: 760, height: 920)
        let chromeModel = FloatingWindowChromeModel()
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.identifier = NSUserInterfaceItemIdentifier(windowKey)
        panel.delegate = self
        panel.title = "Custom Stack — \(source.displayName)"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentMinSize = CGSize(width: 420, height: 520)
        panel.setContentSize(contentSize)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let rootView = WindowScaledRootView(
            configuration: .floatingPanel(referenceSize: contentSize)
        ) {
            CustomMonitorStackWindowRoot(source: source)
                .environmentObject(chromeModel)
        }
        .applyThemeEnvironment()

        panel.contentViewController = NSHostingController(rootView: rootView)
        chromeModel.attach(panel: panel)

        if let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            let topLeft = NSPoint(
                x: anchorWindow.frame.minX + 76,
                y: anchorWindow.frame.maxY - 76
            )
            panel.setFrameTopLeftPoint(topLeft)
        } else {
            panel.center()
        }

        windows[windowKey] = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func addCustomCard(_ entry: FloatingCustomMonitorCardEntry, source: FloatingMonitorCardSource) {
        FloatingCustomMonitorRegistry.shared.upsert(entry)
        CustomMonitorStackStore.shared.addCustom(entry.key, to: source)
        openStack(for: source)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let key = panel.identifier?.rawValue else { return }
        windows.removeValue(forKey: key)
    }
}

private struct FloatingMonitorContextMenuModifier: ViewModifier {
    let cardKind: FloatingMonitorCardKind
    let source: FloatingMonitorCardSource

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Add to Custom Stack") {
                CustomMonitorStackWindowController.shared.addToStack(cardKind, source: source)
            }

            Button("Open Floating Card") {
                FloatingMonitorWindowController.shared.openCard(cardKind, source: source)
            }
        }
    }
}

extension View {
    func floatingMonitorContextMenu(
        cardKind: FloatingMonitorCardKind,
        source: FloatingMonitorCardSource
    ) -> some View {
        modifier(FloatingMonitorContextMenuModifier(cardKind: cardKind, source: source))
    }
}

private struct FloatingMonitorWindowRoot: View {
    let kind: FloatingMonitorCardKind
    let source: FloatingMonitorCardSource

    var body: some View {
        FloatingWindowChrome {
            FloatingMonitorCardContent(kind: kind, source: source)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 10)
                .padding(.bottom, 0)
        }
    }
}

private extension View {
    func floatingSidebarCardFrame() -> some View {
        frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct FloatingCustomMonitorWindowRoot: View {
    let entryKey: String
    @ObservedObject private var registry = FloatingCustomMonitorRegistry.shared

    private var entry: FloatingCustomMonitorCardEntry? {
        _ = registry.revision
        return registry.entry(for: entryKey)
    }

    var body: some View {
        FloatingWindowChrome {
            Group {
                if let entry {
                    entry.content
                } else {
                    Text("This floating card is no longer available.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.bottom, 0)
        }
    }
}

private struct CustomMonitorStackWindowRoot: View {
    let source: FloatingMonitorCardSource
    @ObservedObject private var store: CustomMonitorStackStore
    @State private var savedPresetName = ""

    init(source: FloatingMonitorCardSource) {
        self.source = source
        self._store = ObservedObject(wrappedValue: CustomMonitorStackStore.shared)
    }

    private var state: CustomMonitorStackStore.StackState {
        store.state(for: source)
    }

    private var savedPresets: [CustomMonitorStackStore.SavedStackPreset] {
        store.savedPresets(for: source)
    }

    private var trimmedSavedPresetName: String {
        savedPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSavePreset: Bool {
        trimmedSavedPresetName.isEmpty == false && state.items.isEmpty == false
    }

    private var columns: [GridItem] {
        switch state.layoutMode {
        case .stack:
            return [GridItem(.flexible(minimum: 320), spacing: 18)]
        case .compact:
            return [
                GridItem(.flexible(minimum: 280), spacing: 18),
                GridItem(.flexible(minimum: 280), spacing: 18)
            ]
        }
    }

    private var compactRows: [[CustomMonitorStackItem]] {
        var rows: [[CustomMonitorStackItem]] = []
        var pendingPair: [CustomMonitorStackItem] = []

        for item in state.items {
            if prefersFullWidth(for: item) {
                if pendingPair.isEmpty == false {
                    rows.append(pendingPair)
                    pendingPair.removeAll()
                }
                rows.append([item])
                continue
            }

            pendingPair.append(item)
            if pendingPair.count == 2 {
                rows.append(pendingPair)
                pendingPair.removeAll()
            }
        }

        if pendingPair.isEmpty == false {
            rows.append(pendingPair)
        }

        return rows
    }

    private func prefersFullWidth(for item: CustomMonitorStackItem) -> Bool {
        switch item {
        case .builtIn(let kind):
            return kind.prefersFullWidthInCustomStack
        case .custom(let entryKey):
            return FloatingCustomMonitorRegistry.shared.entry(for: entryKey)?.prefersFullWidthInCustomStack ?? false
        }
    }

    var body: some View {
        FloatingWindowChrome(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 18) {
                header

                if state.items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        Group {
                            switch state.layoutMode {
                            case .stack:
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                    ForEach(Array(state.items.enumerated()), id: \.element) { index, item in
                                        CustomMonitorStackItemView(
                                            item: item,
                                            source: source,
                                            index: index,
                                            count: state.items.count
                                        )
                                    }
                                }
                            case .compact:
                                VStack(alignment: .leading, spacing: 18) {
                                    ForEach(Array(compactRows.enumerated()), id: \.offset) { _, row in
                                        HStack(alignment: .top, spacing: 18) {
                                            ForEach(row, id: \.self) { item in
                                                CustomMonitorStackItemView(
                                                    item: item,
                                                    source: source,
                                                    index: state.items.firstIndex(of: item) ?? 0,
                                                    count: state.items.count
                                                )
                                                .frame(maxWidth: row.count == 1 ? .infinity : nil, alignment: .topLeading)
                                            }

                                            if row.count == 1 {
                                                Spacer(minLength: 0)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.bottom, 4)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .onAppear {
            if savedPresetName.isEmpty, let mostRecentPreset = savedPresets.first {
                savedPresetName = mostRecentPreset.name
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Stack")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Text(source.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer(minLength: 12)

                Picker(
                    "Layout",
                    selection: Binding(
                        get: { state.layoutMode },
                        set: { store.setLayoutMode($0, for: source) }
                    )
                ) {
                    ForEach(CustomMonitorStackLayoutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Button("Clear") {
                    store.clear(source: source)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.white.opacity(0.7))
                .disabled(state.items.isEmpty)
            }

            HStack(spacing: 10) {
                TextField("Name this stack", text: $savedPresetName, onCommit: saveCurrentPreset)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        ThemeRoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )

                Button("Save") {
                    saveCurrentPreset()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(canSavePreset ? 0.82 : 0.36))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(canSavePreset ? 0.10 : 0.04))
                )
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(canSavePreset ? 0.14 : 0.08), lineWidth: 1)
                )
                .disabled(canSavePreset == false)

                Menu {
                    if savedPresets.isEmpty {
                        Button("No saved stacks yet") {}
                            .disabled(true)
                    } else {
                        ForEach(savedPresets) { preset in
                            Button(preset.name) {
                                guard let appliedPreset = store.applySavedPreset(preset.id, to: source) else { return }
                                savedPresetName = appliedPreset.name
                            }
                        }
                    }
                } label: {
                    Text("Recall")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(savedPresets.isEmpty ? 0.36 : 0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            ThemeRoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(savedPresets.isEmpty ? 0.04 : 0.10))
                        )
                        .overlay(
                            ThemeRoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(savedPresets.isEmpty ? 0.08 : 0.14), lineWidth: 1)
                        )
                }
                .menuStyle(.borderlessButton)
                .disabled(savedPresets.isEmpty)
            }
        }
    }

    private func saveCurrentPreset() {
        guard let savedPreset = store.saveCurrentState(named: trimmedSavedPresetName, for: source) else { return }
        savedPresetName = savedPreset.name
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No cards added yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Text("Right-click a hardware card or connected Mac tile and choose Add to Custom Stack.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            ThemeRoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct FloatingWindowChrome<Content: View>: View {
    @EnvironmentObject private var chromeModel: FloatingWindowChromeModel
    var cornerRadius: CGFloat = 20
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            FloatingWindowBackgroundLayers(cornerRadius: cornerRadius)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    FloatingWindowPinButton()
                    FloatingWindowCloseButton()
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .clipShape(ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct FloatingWindowBackgroundLayers: View {
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            TransparentWindowConfigurator(
                cornerRadius: cornerRadius,
                titlebarOverlayColor: .clear,
                enableTitlebarOverlay: false,
                allowsWindowBackgroundDragging: true
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            GlassBackground(
                .hud,
                cornerRadius: cornerRadius,
                shape: ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

private struct FloatingWindowCloseButton: View {
    @EnvironmentObject private var chromeModel: FloatingWindowChromeModel
    @State private var isHovered = false

    var body: some View {
        Button {
            chromeModel.closeWindow()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 0.85 : 0.62))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.11 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct FloatingWindowPinButton: View {
    @EnvironmentObject private var chromeModel: FloatingWindowChromeModel
    @State private var isHovered = false

    var body: some View {
        Button {
            chromeModel.togglePinned()
        } label: {
            Image(systemName: chromeModel.isPinned ? "pin.fill" : "pin.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered || chromeModel.isPinned ? 0.82 : 0.58))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered || chromeModel.isPinned ? 0.10 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .help(chromeModel.isPinned ? "Always on top is enabled" : "Always on top is disabled")
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct CustomMonitorStackItemView: View {
    let item: CustomMonitorStackItem
    let source: FloatingMonitorCardSource
    let index: Int
    let count: Int

    @ObservedObject private var store: CustomMonitorStackStore
    @ObservedObject private var registry = FloatingCustomMonitorRegistry.shared

    init(
        item: CustomMonitorStackItem,
        source: FloatingMonitorCardSource,
        index: Int,
        count: Int
    ) {
        self.item = item
        self.source = source
        self.index = index
        self.count = count
        self._store = ObservedObject(wrappedValue: CustomMonitorStackStore.shared)
    }

    private var title: String {
        switch item {
        case .builtIn(let kind):
            return kind.title
        case .custom(let entryKey):
            _ = registry.revision
            return registry.entry(for: entryKey)?.title ?? "Floating Card"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))

                Spacer(minLength: 10)

                controlButton("arrow.up") {
                    store.move(item, in: source, offset: -1)
                }
                .disabled(index == 0)

                controlButton("arrow.down") {
                    store.move(item, in: source, offset: 1)
                }
                .disabled(index >= count - 1)

                controlButton("rectangle.on.rectangle") {
                    switch item {
                    case .builtIn(let kind):
                        FloatingMonitorWindowController.shared.openCard(kind, source: source)
                    case .custom(let entryKey):
                        guard let entry = registry.entry(for: entryKey) else { return }
                        FloatingMonitorWindowController.shared.openCustomCard(entry)
                    }
                }

                controlButton("xmark") {
                    switch item {
                    case .builtIn(let kind):
                        store.remove(kind, from: source)
                    case .custom(let entryKey):
                        store.removeCustom(entryKey, from: source)
                    }
                }
            }

            switch item {
            case .builtIn(let kind):
                FloatingMonitorCardContent(kind: kind, source: source)
            case .custom(let entryKey):
                FloatingCustomMonitorCardContent(entryKey: entryKey)
            }
        }
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.72))
                .frame(width: 24, height: 24)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct FloatingCustomMonitorCardContent: View {
    let entryKey: String
    @ObservedObject private var registry = FloatingCustomMonitorRegistry.shared

    private var entry: FloatingCustomMonitorCardEntry? {
        _ = registry.revision
        return registry.entry(for: entryKey)
    }

    var body: some View {
        Group {
            if let entry {
                entry.content
            } else {
                Text("This floating card is no longer available.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct FloatingMonitorCardContent: View {
    let kind: FloatingMonitorCardKind
    let source: FloatingMonitorCardSource

    var body: some View {
        switch kind {
        case .hardwareInsights:
            FloatingHardwareInsightsCard(source: source)
        case .periodicAverages:
            FloatingPeriodicAveragesCard(source: source)
        case .activityHeatmap:
            FloatingActivityHeatmapCard(source: source)
        case .topApps:
            FloatingTopAppsCard(source: source)
        case .cpuCores:
            FloatingCPUCoresCard(source: source)
        case .networkStats:
            // Network stats card doesn't have a floating implementation yet
            EmptyView()
        case .stereoOutput:
            FloatingStereoOutputCard()
        case .spectrum:
            FloatingSpectrumCard()
        case .remoteMachineTile:
            FloatingRemoteMachineTileCard(source: source)
        case .gpuUnit:
            EmptyView()
        case .memoryUnit:
            EmptyView()
        }
    }
}

private struct FloatingHardwareInsightsCard: View {
    let source: FloatingMonitorCardSource

    var body: some View {
        switch source {
        case .local:
            FloatingLocalHardwareInsightsCard()
        case .remote(let connection):
            FloatingRemoteHardwareInsightsCard(connection: connection)
        }
    }
}

private struct FloatingPeriodicAveragesCard: View {
    let source: FloatingMonitorCardSource

    var body: some View {
        switch source {
        case .local:
            FloatingLocalPeriodicAveragesCard()
        case .remote(let connection):
            FloatingRemotePeriodicAveragesCard(connection: connection)
        }
    }
}

private struct FloatingTopAppsCard: View {
    let source: FloatingMonitorCardSource

    var body: some View {
        switch source {
        case .local:
            FloatingLocalTopAppsCard()
        case .remote(let connection):
            FloatingRemoteTopAppsCard(connection: connection)
        }
    }
}

private struct FloatingActivityHeatmapCard: View {
    let source: FloatingMonitorCardSource

    var body: some View {
        switch source {
        case .local:
            FloatingLocalActivityHeatmapCard()
        case .remote(let connection):
            FloatingRemoteActivityHeatmapCard(connection: connection)
        }
    }
}

private struct FloatingCPUCoresCard: View {
    let source: FloatingMonitorCardSource

    var body: some View {
        switch source {
        case .local:
            FloatingLocalCPUCoresCard()
        case .remote(let connection):
            FloatingRemoteCPUCoresCard(connection: connection)
        }
    }
}

private struct FloatingStereoOutputCard: View {
    @ObservedObject private var meterModel: SystemAudioOutputMeterModel

    init() {
        _meterModel = ObservedObject(wrappedValue: SystemAudioOutputMeterModel.shared)
    }

    var body: some View {
        if meterModel.isSupportedPlatform {
            SystemOutputMeterCard(
                snapshot: meterModel.snapshot,
                onToggleEnabled: { isEnabled in
                    meterModel.setCaptureEnabled(isEnabled)
                },
                onDetailAction: { actionID in
                    meterModel.performFocusAction(actionID)
                }
            )
            .floatingSidebarCardFrame()
            .onAppear {
                meterModel.activate()
            }
            .onDisappear {
                meterModel.deactivate()
            }
        } else {
            Text("Stereo Output metering is unavailable on this macOS version.")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct FloatingSpectrumCard: View {
    @StateObject private var monitoring = MonitoringState()
    @State private var fftSize: Int = 2048
    @State private var decay: SpectrumView.DecayOption = .medium
    @State private var selectedFreqRange: SpectrumView.FrequencyRangePreset = .fullRange

    var body: some View {
        SpectrumView(
            monitoring: monitoring,
            fftSize: $fftSize,
            decay: $decay,
            selectedFreqRange: $selectedFreqRange
        )
        .floatingSidebarCardFrame()
    }
}

private struct FloatingRemoteMachineTileCard: View {
    let source: FloatingMonitorCardSource

    var body: some View {
        switch source {
        case .local:
            Text("Connected machine tiles are only available for remote sessions.")
                .foregroundColor(.secondary)
        case .remote(let connection):
            RemoteMachineTile(connection: connection) {
                RemoteHardwareManager.shared.selectedMachineID = connection.id
            } onDisconnect: {
                RemoteHardwareManager.shared.disconnect(machineID: connection.id)
            }
            .frame(width: 320)
        }
    }
}

private struct FloatingLocalHardwareInsightsCard: View {
    private let model: HardwareMonitoringModel

    @ObservedObject private var cpuSampler: CPUStatsSampler
    @ObservedObject private var gpuSampler: GPUStatsSampler
    @ObservedObject private var storageSampler: StorageStatsSampler
    @ObservedObject private var aneSampler: ANEStatsSampler
    @ObservedObject private var otherAppsSampler: OtherAppsSampler
    @ObservedObject private var gpuClientsSampler: GPUClientsSampler
    @ObservedObject private var mediaEngineSampler: MediaEngineStatsSampler
    @ObservedObject private var powerSampler: PowerStatsSampler

    init() {
        let model = HardwareMonitoringModel.shared
        self.model = model
        _cpuSampler = ObservedObject(wrappedValue: model.cpuSampler)
        _gpuSampler = ObservedObject(wrappedValue: model.gpuSampler)
        _storageSampler = ObservedObject(wrappedValue: model.storageSampler)
        _aneSampler = ObservedObject(wrappedValue: model.aneSampler)
        _otherAppsSampler = ObservedObject(wrappedValue: model.otherAppsSampler)
        _gpuClientsSampler = ObservedObject(wrappedValue: model.gpuClientsSampler)
        _mediaEngineSampler = ObservedObject(wrappedValue: model.mediaEngineSampler)
        _powerSampler = ObservedObject(wrappedValue: model.powerStatsSampler)
    }

    private var refreshAnchor: Date {
        let timestamps =
            [
                cpuSampler.latestSnapshot?.timestamp,
                aneSampler.latestSnapshot?.timestamp,
                powerSampler.latestSnapshot?.timestamp
            ].compactMap { $0 }
            + gpuSampler.latestDeviceSnapshots.map(\.timestamp)
        return timestamps.max() ?? floatingMonitorFallbackAnchorDate
    }

    var body: some View {
        HardwareInsightsCard(
            insightsService: model.insightsService,
            refreshAnchor: refreshAnchor,
            hasNeuralEngine: aneSampler.hasNeuralEngine,
            primaryGPUID: gpuSampler.gpus.first?.id,
            storageSnapshot: storageSampler.latestCapacitySnapshot,
            mediaActivitySummary: mediaEngineSampler.latestActivitySummary,
            topMemoryRows: otherAppsSampler.topRows.prefix(3).map { (name: $0.name, ramMB: $0.ramMB) },
            gpuActiveAppNames: gpuClientsSampler.activeApps.filter(\.isActive).map(\.name),
            uptimeSeconds: powerSampler.latestSystemSnapshot?.uptimeSeconds,
            cumulativeEnergyWh: powerSampler.cumulativeCombinedEnergyWh,
            appLaunchDate: powerSampler.monitoringSessionStartDate ?? floatingMonitorFallbackAnchorDate,
            sessionSummaryLabel: "Monitoring has been active",
            sessionContextNoun: "monitoring session",
            processCount: powerSampler.processCount,
            perCoreFrequenciesHz: powerSampler.perCoreFrequenciesHz,
            efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
            performanceCoreCount: cpuSampler.performanceCoreCount,
            topAppRows: otherAppsSampler.topRows.map {
                HardwareInsightsCard.TopAppInsightRow(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    uptimeSeconds: $0.uptimeSeconds,
                    ramMB: $0.ramMB,
                    cpuPercent: $0.cpuPercent,
                    isGPUActive: $0.isGPUActive
                )
            }
        )
        .floatingSidebarCardFrame()
    }
}

private struct FloatingRemoteHardwareInsightsCard: View {
    @ObservedObject private var connection: RemoteMachineConnection
    @ObservedObject private var bridge: RemoteMachineHardwareBridge

    init(connection: RemoteMachineConnection) {
        self._connection = ObservedObject(wrappedValue: connection)
        self._bridge = ObservedObject(wrappedValue: RemoteMachineBridgeStore.shared.bridge(for: connection))
    }

    private var refreshAnchor: Date {
        let timestamps =
            [
                bridge.cpuSampler.latestSnapshot?.timestamp,
                bridge.aneSampler.latestSnapshot?.timestamp,
                bridge.powerStatsSampler.latestSnapshot?.timestamp
            ].compactMap { $0 }
            + bridge.gpuSampler.latestDeviceSnapshots.map(\.timestamp)
        return timestamps.max() ?? (connection.sessionStartDate ?? Date())
    }

    var body: some View {
        HardwareInsightsCard(
            insightsService: bridge.insightsService,
            refreshAnchor: refreshAnchor,
            hasNeuralEngine: bridge.aneSampler.hasNeuralEngine,
            primaryGPUID: bridge.gpuSampler.gpus.first?.id,
            storageSnapshot: bridge.storageSampler.latestCapacitySnapshot,
            mediaActivitySummary: bridge.mediaEngineSampler.latestActivitySummary,
            topMemoryRows: bridge.otherAppsSampler.topRows.prefix(3).map { (name: $0.name, ramMB: $0.ramMB) },
            gpuActiveAppNames: bridge.gpuClientsSampler.activeApps.filter(\.isActive).map(\.name),
            uptimeSeconds: bridge.powerStatsSampler.latestSystemSnapshot?.uptimeSeconds,
            cumulativeEnergyWh: bridge.powerStatsSampler.cumulativeCombinedEnergyWh,
            appLaunchDate: connection.sessionStartDate ?? Date(),
            sessionSummaryLabel: "Connection has been active",
            sessionContextNoun: "connection session",
            processCount: bridge.powerStatsSampler.processCount,
            perCoreFrequenciesHz: bridge.powerStatsSampler.perCoreFrequenciesHz,
            efficiencyCoreCount: bridge.cpuSampler.efficiencyCoreCount,
            performanceCoreCount: bridge.cpuSampler.performanceCoreCount,
            topAppRows: bridge.otherAppsSampler.topRows.map {
                HardwareInsightsCard.TopAppInsightRow(
                    name: $0.name,
                    bundleIdentifier: $0.bundleIdentifier,
                    uptimeSeconds: $0.uptimeSeconds,
                    ramMB: $0.ramMB,
                    cpuPercent: $0.cpuPercent,
                    isGPUActive: $0.isGPUActive
                )
            }
        )
        .floatingSidebarCardFrame()
    }
}

private func floatingHistoryRefreshToken(
    dates: [Date?],
    components: [String] = []
) -> String {
    let dateToken = dates.compactMap { $0?.timeIntervalSinceReferenceDate }
        .map { String(format: "%.3f", $0) }
        .joined(separator: "|")
    return ([dateToken] + components).joined(separator: "|")
}

private struct FloatingLocalPeriodicAveragesCard: View {
    private let model: HardwareMonitoringModel
    @ObservedObject private var cpuSampler: CPUStatsSampler
    @ObservedObject private var ramSampler: RAMStatsSampler
    @ObservedObject private var diskIOSampler: DiskIOSampler
    @ObservedObject private var networkSampler: NetworkStatsSampler
    @ObservedObject private var aneSampler: ANEStatsSampler
    @ObservedObject private var gpuSampler: GPUStatsSampler
    @ObservedObject private var mediaEngineSampler: MediaEngineStatsSampler
    @ObservedObject private var powerSampler: PowerStatsSampler

    init() {
        let model = HardwareMonitoringModel.shared
        self.model = model
        _cpuSampler = ObservedObject(wrappedValue: model.cpuSampler)
        _ramSampler = ObservedObject(wrappedValue: model.ramSampler)
        _diskIOSampler = ObservedObject(wrappedValue: model.diskIOSampler)
        _networkSampler = ObservedObject(wrappedValue: model.networkSampler)
        _aneSampler = ObservedObject(wrappedValue: model.aneSampler)
        _gpuSampler = ObservedObject(wrappedValue: model.gpuSampler)
        _mediaEngineSampler = ObservedObject(wrappedValue: model.mediaEngineSampler)
        _powerSampler = ObservedObject(wrappedValue: model.powerStatsSampler)
    }

    private var historyRefreshToken: String {
        floatingHistoryRefreshToken(
            dates: [
                cpuSampler.latestSnapshot?.timestamp,
                ramSampler.latestSnapshot?.timestamp,
                diskIOSampler.latestSnapshot?.timestamp,
                networkSampler.latestSnapshot?.timestamp,
                aneSampler.latestSnapshot?.timestamp,
                mediaEngineSampler.latestSnapshot?.timestamp,
                powerSampler.latestSnapshot?.timestamp
            ] + gpuSampler.latestDeviceSnapshots.map(\.timestamp).map(Optional.some),
            components: [gpuSampler.gpus.map(\.id).joined(separator: "|")]
        )
    }

    var body: some View {
        PeriodicAveragesCard(
            historyReader: model.historyReader,
            hasNeuralEngine: aneSampler.hasNeuralEngine,
            primaryGPUID: gpuSampler.gpus.first?.id,
            historyRefreshToken: historyRefreshToken
        )
        .frame(width: 760)
    }
}

private struct FloatingRemotePeriodicAveragesCard: View {
    @ObservedObject private var bridge: RemoteMachineHardwareBridge
    @ObservedObject private var cpuSampler: CPUStatsSampler
    @ObservedObject private var ramSampler: RAMStatsSampler
    @ObservedObject private var diskIOSampler: DiskIOSampler
    @ObservedObject private var networkSampler: NetworkStatsSampler
    @ObservedObject private var aneSampler: ANEStatsSampler
    @ObservedObject private var gpuSampler: GPUStatsSampler
    @ObservedObject private var mediaEngineSampler: MediaEngineStatsSampler
    @ObservedObject private var powerSampler: PowerStatsSampler

    init(connection: RemoteMachineConnection) {
        let bridge = RemoteMachineBridgeStore.shared.bridge(for: connection)
        self._bridge = ObservedObject(wrappedValue: bridge)
        self._cpuSampler = ObservedObject(wrappedValue: bridge.cpuSampler)
        self._ramSampler = ObservedObject(wrappedValue: bridge.ramSampler)
        self._diskIOSampler = ObservedObject(wrappedValue: bridge.diskIOSampler)
        self._networkSampler = ObservedObject(wrappedValue: bridge.networkSampler)
        self._aneSampler = ObservedObject(wrappedValue: bridge.aneSampler)
        self._gpuSampler = ObservedObject(wrappedValue: bridge.gpuSampler)
        self._mediaEngineSampler = ObservedObject(wrappedValue: bridge.mediaEngineSampler)
        self._powerSampler = ObservedObject(wrappedValue: bridge.powerStatsSampler)
    }

    private var historyRefreshToken: String {
        floatingHistoryRefreshToken(
            dates: [
                bridge.latestTelemetryFrame.timestamp,
                cpuSampler.latestSnapshot?.timestamp,
                ramSampler.latestSnapshot?.timestamp,
                diskIOSampler.latestSnapshot?.timestamp,
                networkSampler.latestSnapshot?.timestamp,
                aneSampler.latestSnapshot?.timestamp,
                mediaEngineSampler.latestSnapshot?.timestamp,
                powerSampler.latestSnapshot?.timestamp
            ] + gpuSampler.latestDeviceSnapshots.map(\.timestamp).map(Optional.some),
            components: [gpuSampler.gpus.map(\.id).joined(separator: "|")]
        )
    }

    var body: some View {
        PeriodicAveragesCard(
            historyReader: bridge.historyReader,
            hasNeuralEngine: bridge.aneSampler.hasNeuralEngine,
            primaryGPUID: bridge.gpuSampler.gpus.first?.id,
            historyRefreshToken: historyRefreshToken
        )
        .frame(width: 760)
    }
}

private struct FloatingLocalTopAppsCard: View {
    private let model: HardwareMonitoringModel
    @ObservedObject private var otherAppsSampler: OtherAppsSampler

    init() {
        let model = HardwareMonitoringModel.shared
        self.model = model
        _otherAppsSampler = ObservedObject(wrappedValue: model.otherAppsSampler)
    }

    var body: some View {
        TopAppsCard(
            rows: otherAppsSampler.resourceRankedRows,
            liveHistoryProvider: { identity in
                otherAppsSampler.liveHistorySnapshot(for: identity)
            }
        )
        .floatingSidebarCardFrame()
    }
}

private struct FloatingRemoteTopAppsCard: View {
    @ObservedObject private var bridge: RemoteMachineHardwareBridge

    init(connection: RemoteMachineConnection) {
        self._bridge = ObservedObject(wrappedValue: RemoteMachineBridgeStore.shared.bridge(for: connection))
    }

    var body: some View {
        TopAppsCard(
            rows: bridge.otherAppsSampler.resourceRankedRows,
            liveHistoryProvider: { identity in
                bridge.otherAppsSampler.liveHistorySnapshot(for: identity)
            }
        )
        .floatingSidebarCardFrame()
    }
}

private struct FloatingLocalActivityHeatmapCard: View {
    private let model: HardwareMonitoringModel
    @ObservedObject private var gpuSampler: GPUStatsSampler
    @ObservedObject private var aneSampler: ANEStatsSampler

    init() {
        let model = HardwareMonitoringModel.shared
        self.model = model
        _gpuSampler = ObservedObject(wrappedValue: model.gpuSampler)
        _aneSampler = ObservedObject(wrappedValue: model.aneSampler)
    }

    var body: some View {
        ActivityHeatmapCard(
            historyReader: model.historyReader,
            primaryGPUID: gpuSampler.gpus.first?.id,
            hasNeuralEngine: aneSampler.hasNeuralEngine
        )
        .frame(width: 760)
    }
}

private struct FloatingRemoteActivityHeatmapCard: View {
    @ObservedObject private var bridge: RemoteMachineHardwareBridge

    init(connection: RemoteMachineConnection) {
        self._bridge = ObservedObject(wrappedValue: RemoteMachineBridgeStore.shared.bridge(for: connection))
    }

    var body: some View {
        ActivityHeatmapCard(
            historyReader: bridge.historyReader,
            primaryGPUID: bridge.gpuSampler.gpus.first?.id,
            hasNeuralEngine: bridge.aneSampler.hasNeuralEngine
        )
        .frame(width: 760)
    }
}

private struct FloatingLocalCPUCoresCard: View {
    private let model: HardwareMonitoringModel
    @ObservedObject private var cpuSampler: CPUStatsSampler
    @ObservedObject private var powerSampler: PowerStatsSampler

    init() {
        let model = HardwareMonitoringModel.shared
        self.model = model
        _cpuSampler = ObservedObject(wrappedValue: model.cpuSampler)
        _powerSampler = ObservedObject(wrappedValue: model.powerStatsSampler)
    }

    var body: some View {
        CPUCoresCard(
            cpuDisplayName: cpuSampler.cpuDisplayName,
            coreUsages: cpuSampler.coreUsages,
            perCoreFrequenciesHz: powerSampler.perCoreFrequenciesHz,
            perCoreUsageSeries: cpuSampler.perCoreUsageSeries,
            perCoreFrequencySeries: powerSampler.perCoreFrequencySeries,
            efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
            performanceCoreCount: cpuSampler.performanceCoreCount
        )
        .floatingSidebarCardFrame()
    }
}

private struct FloatingRemoteCPUCoresCard: View {
    @ObservedObject private var bridge: RemoteMachineHardwareBridge
    @ObservedObject private var cpuSampler: CPUStatsSampler
    @ObservedObject private var powerSampler: PowerStatsSampler

    init(connection: RemoteMachineConnection) {
        let bridge = RemoteMachineBridgeStore.shared.bridge(for: connection)
        self._bridge = ObservedObject(wrappedValue: bridge)
        self._cpuSampler = ObservedObject(wrappedValue: bridge.cpuSampler)
        self._powerSampler = ObservedObject(wrappedValue: bridge.powerStatsSampler)
    }

    var body: some View {
        CPUCoresCard(
            cpuDisplayName: cpuSampler.cpuDisplayName,
            coreUsages: cpuSampler.coreUsages,
            perCoreFrequenciesHz: powerSampler.perCoreFrequenciesHz,
            perCoreUsageSeries: cpuSampler.perCoreUsageSeries,
            perCoreFrequencySeries: powerSampler.perCoreFrequencySeries,
            efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
            performanceCoreCount: cpuSampler.performanceCoreCount
        )
        .floatingSidebarCardFrame()
    }
}
