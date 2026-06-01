//
//  FloatingWindowController.swift
//  AVCMeter
//
//  Created by Chris Izatt on 08/07/2025.
//

import CoreAudio
import SwiftUI
import AppKit
import Foundation
import FireWireNetBridgeKit

private let sharedStreamManager = MultiDeviceStreamManager.shared

// Notification names for floating window close events
extension Notification.Name {
    static let floatingSpectrumWindowDidClose = Notification.Name("floatingSpectrumWindowDidClose")
    static let floatingWaveformWindowDidClose = Notification.Name("floatingWaveformWindowDidClose")
    static let floatingSpectrogramWindowDidClose = Notification.Name("floatingSpectrogramWindowDidClose")
    static let floatingPianoKeyboardWindowDidClose = Notification.Name("floatingPianoKeyboardWindowDidClose")
    static let floatingMIDICCControlWindowDidClose = Notification.Name("floatingMIDICCControlWindowDidClose")
}

extension Notification {
    fileprivate var floatingWindowKey: String? {
        userInfo?["key"] as? String
    }

    func matchesFloatingWindow(deviceID: AudioDeviceID, channelIndex: Int, suffix: String) -> Bool {
        floatingWindowKey == "\(deviceID)-\(channelIndex)-\(suffix)"
    }

    func floatingWindowChannelIndex(deviceID: AudioDeviceID, suffix: String) -> Int? {
        guard let key = floatingWindowKey else { return nil }

        let prefix = "\(deviceID)-"
        let suffixToken = "-\(suffix)"
        guard key.hasPrefix(prefix), key.hasSuffix(suffixToken) else { return nil }

        let channelStart = key.index(key.startIndex, offsetBy: prefix.count)
        let channelEnd = key.index(key.endIndex, offsetBy: -suffixToken.count)
        guard channelStart <= channelEnd else { return nil }

        return Int(key[channelStart..<channelEnd])
    }
}

/// Floating window controller for embedding SwiftUI in NSPanel (macOS only)
#if os(macOS)

private final class PanelCloseObserver: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private final class PanelPinAccessoryController: NSObject {
    weak var panel: NSPanel?
    let accessoryController = NSTitlebarAccessoryViewController()
    let button: NSButton
private(set) var isPinned: Bool = false

    init(panel: NSPanel) {
        self.panel = panel
        self.button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
        super.init()

        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePinnedState(_:))
        button.toolTip = "Toggle Always on Top"

        accessoryController.view = button
        accessoryController.layoutAttribute = .right

        applyPinnedState(animated: false)
    }

    @objc private func togglePinnedState(_ sender: NSButton) {
        isPinned.toggle()
        applyPinnedState(animated: true)
    }

    private func applyPinnedState(animated: Bool) {
        guard let panel else { return }

        panel.level = isPinned ? .floating : .normal
        panel.isFloatingPanel = isPinned

        if #available(macOS 11.0, *) {
            let imageName = isPinned ? "pin.fill" : "pin.slash"
            button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: isPinned ? "Pinned" : "Unpinned")
        } else {
            button.title = "P"
        }

        button.contentTintColor = isPinned ? .systemYellow : .secondaryLabelColor
        button.toolTip = isPinned ? "Disable Always on Top" : "Enable Always on Top"

        if animated {
            panel.animator().alphaValue = 1.0
        }
    }
}

class FloatingWindowController: ObservableObject {
    static let shared = FloatingWindowController()

    private var spectrumWindows: [String: NSPanel] = [:]
    private var waveformWindows: [String: NSPanel] = [:]
    private var spectrogramWindows: [String: NSPanel] = [:]
    private var inputEQWindows: [String: NSPanel] = [:]
    private var inputDynamicsWindows: [String: NSPanel] = [:]
    private var outputEQWindows: [String: NSPanel] = [:]
    private var outputDynamicsWindows: [String: NSPanel] = [:]
    private var virtualEQWindows: [String: NSPanel] = [:]
    private var virtualDynamicsWindows: [String: NSPanel] = [:]
    private var virtualInstrumentPluginWindows: [String: NSPanel] = [:]
    private var pianoKeyboardWindows: [String: NSPanel] = [:]
    private var midiCCControlWindows: [String: NSPanel] = [:]
    var mixerWindow: NSPanel?
    var outputMixerWindow: NSPanel?
    var returnMixerWindow: NSPanel?
    var sendsMixerWindow: NSPanel?
    var virtualInstrumentMixerWindow: NSPanel?
    var dcaMixerWindow: NSPanel?
    var allMixersWindow: NSPanel?
    var routingWindow: NSPanel?
    var synthesizerWindow: NSPanel?
    var drumMachineWindow: NSPanel?
    var toneGeneratorWindow: NSPanel?
    var physicalModelWindow: NSPanel?
    var samplerWindow: NSPanel?
    var globalChannelWindow: NSPanel?
    var fireWireNetBridgeWindow: NSPanel?
    private var floatingMeterWindows: [String: NSPanel] = [:]
    private var closeObservers: [ObjectIdentifier: PanelCloseObserver] = [:]
    private var pinAccessoryControllers: [ObjectIdentifier: PanelPinAccessoryController] = [:]

    private func panelKey(for deviceID: AudioDeviceID, channelIndex: Int?, suffix: String) -> String {
        if let channelIndex {
            return "\(deviceID)-\(channelIndex)-\(suffix)"
        }
        return "\(deviceID)-\(suffix)"
    }

    private func registerLifecycle(for panel: NSPanel, notificationName: Notification.Name? = nil, key: String? = nil, onClose: @escaping () -> Void) {
        let identifier = ObjectIdentifier(panel)
        let observer = PanelCloseObserver { [weak self, weak panel] in
            if let panel {
                let identifier = ObjectIdentifier(panel)
                self?.closeObservers.removeValue(forKey: identifier)
                self?.pinAccessoryControllers.removeValue(forKey: identifier)
            }
            if let notificationName = notificationName, let key = key {
                NotificationCenter.default.post(name: notificationName, object: nil, userInfo: ["key": key])
            }
            onClose()
        }
        closeObservers[identifier] = observer
        panel.delegate = observer
        panel.standardWindowButton(.closeButton)?.isHidden = false
    }

    private func installPinAccessoryIfNeeded(for panel: NSPanel) {
        let identifier = ObjectIdentifier(panel)
        guard pinAccessoryControllers[identifier] == nil else { return }

        let controller = PanelPinAccessoryController(panel: panel)
        panel.addTitlebarAccessoryViewController(controller.accessoryController)
        pinAccessoryControllers[identifier] = controller
    }

    private func configurePanelForCurrentTheme(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        if !panel.styleMask.contains(.fullSizeContentView) {
            panel.styleMask.insert(.fullSizeContentView)
        }

        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        installPinAccessoryIfNeeded(for: panel)
    }

    func showSpectrumWindow<Content: View>(
        deviceID: AudioDeviceID,
        channelIndex: Int? = nil,
        scale: CGFloat = 1.0,
        title: String = "Spectrum",
        @ViewBuilder content: @escaping () -> Content
    ) {
        let baseWidth: CGFloat = 750
        let baseHeight: CGFloat = 380
        let scaledWidth = baseWidth * scale
        let scaledHeight = baseHeight * scale
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "spectrum")
        if spectrumWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.becomesKeyOnlyIfNeeded = false
            panel.ignoresMouseEvents = false
            panel.title = title
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            registerLifecycle(for: panel, notificationName: .floatingSpectrumWindowDidClose, key: key) { [weak self] in
                self?.spectrumWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            spectrumWindows[key] = panel
        } else {
            spectrumWindows[key]?.title = title
            spectrumWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeSpectrumWindow(for deviceID: AudioDeviceID, channelIndex: Int? = nil) {
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "spectrum")
        spectrumWindows[key]?.close()
        spectrumWindows[key] = nil
    }

    func showSpectrogramWindow<Content: View>(
        deviceID: AudioDeviceID,
        channelIndex: Int? = nil,
        scale: CGFloat = 1.0,
        title: String = "Spectrogram",
        @ViewBuilder content: @escaping () -> Content
    ) {
        let baseWidth: CGFloat = 750
        let baseHeight: CGFloat = 380
        let scaledWidth = baseWidth * scale
        let scaledHeight = baseHeight * scale
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "spectrogram")
        if spectrogramWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.becomesKeyOnlyIfNeeded = false
            panel.ignoresMouseEvents = false
            panel.title = title
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(width: scaledWidth, height: scaledHeight)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            registerLifecycle(for: panel, notificationName: .floatingSpectrogramWindowDidClose, key: key) { [weak self] in
                self?.spectrogramWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            spectrogramWindows[key] = panel
        } else {
            spectrogramWindows[key]?.title = title
            let newFrame = NSRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)
            spectrogramWindows[key]?.setFrame(newFrame, display: true, animate: true)
            spectrogramWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeSpectrogramWindow(for deviceID: AudioDeviceID, channelIndex: Int? = nil) {
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "spectrogram")
        spectrogramWindows[key]?.close()
        spectrogramWindows[key] = nil
    }

    func showWaveformWindow<Content: View>(
        deviceID: AudioDeviceID,
        channelIndex: Int? = nil,
        scale: CGFloat = 1.0,
        title: String = "Waveform",
        @ViewBuilder content: @escaping () -> Content
    ) {
        let baseWidth: CGFloat = 750
        let baseHeight: CGFloat = 180
        let scaledWidth = baseWidth * scale
        let scaledHeight = baseHeight * scale
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "waveform")
        if waveformWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.becomesKeyOnlyIfNeeded = false
            panel.ignoresMouseEvents = false
            panel.title = title
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(width: scaledWidth, height: scaledHeight)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            registerLifecycle(for: panel, notificationName: .floatingWaveformWindowDidClose, key: key) { [weak self] in
                self?.waveformWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            waveformWindows[key] = panel
        } else {
            waveformWindows[key]?.title = title
            let newFrame = NSRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight)
            waveformWindows[key]?.setFrame(newFrame, display: true, animate: true)
            waveformWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeWaveformWindow(for deviceID: AudioDeviceID, channelIndex: Int? = nil) {
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "waveform")
        waveformWindows[key]?.close()
        waveformWindows[key] = nil
    }

    func showInputEQWindow<Content: View>(
        deviceID: AudioDeviceID,
        channelIndex: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "\(deviceID)-eq-\(channelIndex)"
        if inputEQWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 450),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "EQ"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 860, idealWidth: 860, maxWidth: .infinity,
                               minHeight: 450, idealHeight: 450, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.inputEQWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            inputEQWindows[key] = panel
        } else {
            inputEQWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeInputEQWindow(deviceID: AudioDeviceID, channelIndex: Int) {
        let key = "\(deviceID)-eq-\(channelIndex)"
        inputEQWindows[key]?.close()
        inputEQWindows[key] = nil
    }

    func showInputDynamicsWindow<Content: View>(
        deviceID: AudioDeviceID,
        channelIndex: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "\(deviceID)-dyn-\(channelIndex)"
        if inputDynamicsWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 450),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "Dynamics"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 860, idealWidth: 860, maxWidth: .infinity,
                               minHeight: 450, idealHeight: 450, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.inputDynamicsWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            inputDynamicsWindows[key] = panel
        } else {
            inputDynamicsWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeInputDynamicsWindow(deviceID: AudioDeviceID, channelIndex: Int) {
        let key = "\(deviceID)-dyn-\(channelIndex)"
        inputDynamicsWindows[key]?.close()
        inputDynamicsWindows[key] = nil
    }

    func showOutputEQWindow<Content: View>(
        deviceID: AudioDeviceID,
        channelIndex: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "\(deviceID)-output-eq-\(channelIndex)"
        if outputEQWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "EQ"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 820, idealWidth: 960, maxWidth: .infinity,
                               minHeight: 680, idealHeight: 760, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.outputEQWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            outputEQWindows[key] = panel
        } else {
            outputEQWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeOutputEQWindow(deviceID: AudioDeviceID, channelIndex: Int) {
        let key = "\(deviceID)-output-eq-\(channelIndex)"
        outputEQWindows[key]?.close()
        outputEQWindows[key] = nil
    }

    func showOutputDynamicsWindow<Content: View>(
        deviceID: AudioDeviceID,
        channelIndex: Int,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "\(deviceID)-output-dyn-\(channelIndex)"
        if outputDynamicsWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 450),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "Dynamics"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 860, idealWidth: 860, maxWidth: .infinity,
                               minHeight: 450, idealHeight: 450, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.outputDynamicsWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            outputDynamicsWindows[key] = panel
        } else {
            outputDynamicsWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeOutputDynamicsWindow(deviceID: AudioDeviceID, channelIndex: Int) {
        let key = "\(deviceID)-output-dyn-\(channelIndex)"
        outputDynamicsWindows[key]?.close()
        outputDynamicsWindows[key] = nil
    }

    func showVirtualEQWindow<Content: View>(
        channelID: UUID,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "\(channelID.uuidString)-virtual-eq"
        if virtualEQWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "EQ"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 820, idealWidth: 960, maxWidth: .infinity,
                               minHeight: 680, idealHeight: 760, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.virtualEQWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            virtualEQWindows[key] = panel
        } else {
            virtualEQWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeVirtualEQWindow(channelID: UUID) {
        let key = "\(channelID.uuidString)-virtual-eq"
        virtualEQWindows[key]?.close()
        virtualEQWindows[key] = nil
    }

    func showVirtualDynamicsWindow<Content: View>(
        channelID: UUID,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "\(channelID.uuidString)-virtual-dyn"
        if virtualDynamicsWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 450),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "Dynamics"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 860, idealWidth: 860, maxWidth: .infinity,
                               minHeight: 450, idealHeight: 450, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.virtualDynamicsWindows[key] = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            virtualDynamicsWindows[key] = panel
        } else {
            virtualDynamicsWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeVirtualDynamicsWindow(channelID: UUID) {
        let key = "\(channelID.uuidString)-virtual-dyn"
        virtualDynamicsWindows[key]?.close()
        virtualDynamicsWindows[key] = nil
    }

    func showVirtualInstrumentPluginWindow(
        deviceID: AudioDeviceID,
        channelIndex: Int,
        title: String,
        viewController: NSViewController?
    ) {
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "vi-plugin")

        if let existingPanel = virtualInstrumentPluginWindows[key] {
            existingPanel.title = title
            if let viewController {
                existingPanel.contentViewController = viewController
            } else {
                existingPanel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                        VStack(spacing: 10) {
                            Text("No Plugin UI Available")
                                .font(.headline)
                            Text("This instrument does not provide a custom editor window.")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    })
                    .environmentObject(ThemeManager.shared)
                )
            }
            existingPanel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.title = title

        if let viewController {
            panel.contentViewController = viewController
        } else {
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    VStack(spacing: 10) {
                        Text("No Plugin UI Available")
                            .font(.headline)
                        Text("This instrument does not provide a custom editor window.")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
        }

        registerLifecycle(for: panel) { [weak self] in
            self?.virtualInstrumentPluginWindows[key] = nil
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        virtualInstrumentPluginWindows[key] = panel
    }

    func closeVirtualInstrumentPluginWindow(deviceID: AudioDeviceID, channelIndex: Int) {
        let key = panelKey(for: deviceID, channelIndex: channelIndex, suffix: "vi-plugin")
        virtualInstrumentPluginWindows[key]?.close()
        virtualInstrumentPluginWindows[key] = nil
    }

    // MARK: - Mixer Window Support
    func showMixerWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if mixerWindow == nil {
            Task { @MainActor in
                let themeManager = ThemeManager.shared
                let extraStrips = max(0, sharedStreamManager.activePollers.values.flatMap { $0.channelMask }.filter { $0 }.count - 10)
                let additionalWidth = CGFloat(extraStrips) * 48.0
                let finalWidth = 880 + additionalWidth
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
                    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "Mixer"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                    content()
                    .frame(minWidth: 300, idealWidth: 450, maxWidth: .infinity, minHeight: 800, idealHeight: 900, maxHeight: .infinity)
                    .environmentObject(themeManager)
                    })
                    .environmentObject(ThemeManager.shared)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.mixerWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.mixerWindow = panel
            }
            return
        } else {
            mixerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeMixerWindow() {
        mixerWindow?.close()
        mixerWindow = nil
    }

    // MARK: - Output Mixer Window Support
    func showOutputMixerWindow<Content: View>(
        themeManager: ThemeManager,
        @ViewBuilder content: @escaping () -> Content
    ) {
        if outputMixerWindow == nil {
            Task { @MainActor in
                let outputManager = OutputDeviceManager.shared
                let themeManager = ThemeManager.shared
                let channelCount = outputManager.selectedChannelMasks.values.reduce(0) { $0 + $1.filter { $0 }.count }
                let extraStrips = max(0, channelCount - 10)
                let additionalWidth = CGFloat(extraStrips) * 48.0
                let finalWidth = 880 + additionalWidth

                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: finalWidth, height: 450),
                    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "Output Mixer"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                    content()
                    .frame(minWidth: 300, idealWidth: 450, maxWidth: .infinity, minHeight: 800, idealHeight: 900, maxHeight: .infinity)
                    .environmentObject(themeManager)
                    })
                    .environmentObject(themeManager)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.outputMixerWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.outputMixerWindow = panel
            }
        } else {
            outputMixerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeOutputMixerWindow() {
        outputMixerWindow?.close()
        outputMixerWindow = nil
    }

    // MARK: - Return Mixer Window Support
    func showReturnMixerWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if returnMixerWindow == nil {
            Task { @MainActor in
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 880, height: 450),
                    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "Aux/FX Return Mixer"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                        content()
                            .frame(minWidth: 800, idealWidth: 880, maxWidth: .infinity, minHeight: 800, idealHeight: 1200, maxHeight: .infinity)
                    })
                    .environmentObject(ThemeManager.shared)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.returnMixerWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.returnMixerWindow = panel
            }
        } else {
            returnMixerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeReturnMixerWindow() {
        returnMixerWindow?.close()
        returnMixerWindow = nil
    }

    // MARK: - Sends Mixer Window Support
    func showSendsMixerWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if sendsMixerWindow == nil {
            Task { @MainActor in
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 880, height: 450),
                    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "FX/Aux Send Mixer"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                        content()
                            .frame(minWidth: 800, idealWidth: 880, maxWidth: .infinity, minHeight: 800, idealHeight: 1200, maxHeight: .infinity)
                    })
                    .environmentObject(ThemeManager.shared)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.sendsMixerWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.sendsMixerWindow = panel
            }
        } else {
            sendsMixerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeSendsMixerWindow() {
        sendsMixerWindow?.close()
        sendsMixerWindow = nil
    }

    // MARK: - Virtual Instrument Mixer Window Support
    func showVirtualInstrumentMixerWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if virtualInstrumentMixerWindow == nil {
            Task { @MainActor in
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 880, height: 450),
                    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "Virtual Instrument Mixer"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                        content()
                            .frame(minWidth: 800, idealWidth: 880, maxWidth: .infinity, minHeight: 800, idealHeight: 1200, maxHeight: .infinity)
                    })
                    .environmentObject(ThemeManager.shared)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.virtualInstrumentMixerWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.virtualInstrumentMixerWindow = panel
            }
        } else {
            virtualInstrumentMixerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeVirtualInstrumentMixerWindow() {
        virtualInstrumentMixerWindow?.close()
        virtualInstrumentMixerWindow = nil
    }

    // MARK: - DCA Mixer Window Support
    func showDCAMixerWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if dcaMixerWindow == nil {
            Task { @MainActor in
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 880, height: 450),
                    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "DCA Mixer"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                        content()
                            .frame(minWidth: 800, idealWidth: 880, maxWidth: .infinity, minHeight: 800, idealHeight: 1200, maxHeight: .infinity)
                    })
                    .environmentObject(ThemeManager.shared)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.dcaMixerWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.dcaMixerWindow = panel
            }
        } else {
            dcaMixerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeDCAMixerWindow() {
        dcaMixerWindow?.close()
        dcaMixerWindow = nil
    }

    // MARK: - All Mixers Window Support
    func showAllMixersWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if allMixersWindow == nil {
            Task { @MainActor in
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 880, height: 450),
                    styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "All Mixers"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                        content()
                            .frame(minWidth: 800, idealWidth: 880, maxWidth: .infinity, minHeight: 800, idealHeight: 1200, maxHeight: .infinity)
                    })
                    .environmentObject(ThemeManager.shared)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.allMixersWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.allMixersWindow = panel
            }
        } else {
            allMixersWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeAllMixersWindow() {
        allMixersWindow?.close()
        allMixersWindow = nil
    }

    // MARK: - Floating Meter Windows

    func showFloatingMeterWindow<Content: View>(
        key: String,
        title: String,
        size: CGSize,
        @ViewBuilder content: @escaping () -> Content
    ) {
        if let existing = floatingMeterWindows[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        panel.contentView = NSHostingView(rootView:
            HoverableFloatingMeterView(title: title, onClose: { [weak panel] in
                panel?.close()
            }) {
                content()
            }
            .environmentObject(ThemeManager.shared)
        )
        registerLifecycle(for: panel) { [weak self] in
            self?.floatingMeterWindows[key] = nil
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        floatingMeterWindows[key] = panel
    }

    func closeFloatingMeterWindow(key: String) {
        floatingMeterWindows[key]?.close()
        floatingMeterWindows[key] = nil
    }

    func showRoutingWindow<Content: View>(
        scale: CGFloat = 1.0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        let baseWidth: CGFloat = 800
        let baseHeight: CGFloat = 600
        let scaledWidth = baseWidth * scale
        let scaledHeight = baseHeight * scale

        if routingWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.becomesKeyOnlyIfNeeded = false
            panel.ignoresMouseEvents = false
            panel.title = "Routing Matrix"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(width: scaledWidth, height: scaledHeight)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.routingWindow = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            routingWindow = panel
        } else {
            routingWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeRoutingWindow() {
        routingWindow?.close()
        routingWindow = nil
    }

    // MARK: - Utility Instrument Windows

    func showSynthesizerWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if synthesizerWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "Synthesizer Engine"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 800, idealWidth: 960, maxWidth: .infinity,
                               minHeight: 500, idealHeight: 600, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.synthesizerWindow = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            synthesizerWindow = panel
        } else {
            synthesizerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeSynthesizerWindow() {
        synthesizerWindow?.close()
        synthesizerWindow = nil
    }

    func showPhysicalModelWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if physicalModelWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "Physical Model Synth"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 600, idealWidth: 900, maxWidth: .infinity,
                               minHeight: 400, idealHeight: 500, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.physicalModelWindow = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            physicalModelWindow = panel
        } else {
            physicalModelWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closePhysicalModelWindow() {
        physicalModelWindow?.close()
        physicalModelWindow = nil
    }

    func showSamplerWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if samplerWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 950, height: 600),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "Sampler Engine"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 700, idealWidth: 950, maxWidth: .infinity,
                               minHeight: 500, idealHeight: 600, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.samplerWindow = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            samplerWindow = panel
        } else {
            samplerWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeSamplerWindow() {
        samplerWindow?.close()
        samplerWindow = nil
    }

    func showDrumMachineWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if drumMachineWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "808 Drum Machine"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 800, idealWidth: 920, maxWidth: .infinity,
                               minHeight: 500, idealHeight: 580, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.drumMachineWindow = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            drumMachineWindow = panel
        } else {
            drumMachineWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeDrumMachineWindow() {
        drumMachineWindow?.close()
        drumMachineWindow = nil
    }

    func showToneGeneratorWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if toneGeneratorWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 850, height: 500),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "Tone Generator"
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(minWidth: 600, idealWidth: 850, maxWidth: .infinity,
                               minHeight: 400, idealHeight: 500, maxHeight: .infinity)
                })
                .environmentObject(ThemeManager.shared)
            )
            configurePanelForCurrentTheme(panel)
            panel.isMovableByWindowBackground = false
            registerLifecycle(for: panel) { [weak self] in
                self?.toneGeneratorWindow = nil
            }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            toneGeneratorWindow = panel
        } else {
            toneGeneratorWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeToneGeneratorWindow() {
        toneGeneratorWindow?.close()
        toneGeneratorWindow = nil
    }

    func showPianoKeyboardWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "piano-keyboard"
        if pianoKeyboardWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 225),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "On-Screen Keyboard"
            panel.backgroundColor = .clear
            panel.contentView = NSHostingView(rootView:
                FloatingWindowHostingView(content: {
                    content()
                        .frame(width: 980, height: 225)
                        .background(Color.clear)
                })
            )
            let observer = PanelCloseObserver { [weak self] in
                self?.pianoKeyboardWindows[key] = nil
                NotificationCenter.default.post(name: .floatingPianoKeyboardWindowDidClose, object: nil)
            }
            panel.delegate = observer
            closeObservers[ObjectIdentifier(panel)] = observer
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            pianoKeyboardWindows[key] = panel
        } else {
            pianoKeyboardWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closePianoKeyboardWindow() {
        pianoKeyboardWindows["piano-keyboard"]?.close()
        pianoKeyboardWindows["piano-keyboard"] = nil
    }

    func showMIDICCControlWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        let key = "midi-cc-control"
        if midiCCControlWindows[key] == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.title = "MIDI CC Control"
            panel.contentView = NSHostingView(
                rootView: content()
            )
            let observer = PanelCloseObserver { [weak self] in
                self?.midiCCControlWindows[key] = nil
                NotificationCenter.default.post(name: .floatingMIDICCControlWindowDidClose, object: nil)
            }
            panel.delegate = observer
            closeObservers[ObjectIdentifier(panel)] = observer
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            midiCCControlWindows[key] = panel
        } else {
            midiCCControlWindows[key]?.makeKeyAndOrderFront(nil)
        }
    }

    func closeMIDICCControlWindow() {
        midiCCControlWindows["midi-cc-control"]?.close()
        midiCCControlWindows["midi-cc-control"] = nil
    }

    func showGlobalChannelWindow<Content: View>(
        @ViewBuilder content: @escaping () -> Content
    ) {
        if globalChannelWindow == nil {
            Task { @MainActor in
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                    styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "Global Channel Log"
                panel.contentView = NSHostingView(rootView:
                    FloatingWindowHostingView(content: {
                        content()
                            .frame(minWidth: 400, idealWidth: 500, maxWidth: .infinity,
                                   minHeight: 300, idealHeight: 400, maxHeight: .infinity)
                            .background(Color.white.opacity(0.05))
                    })
                    .environmentObject(ThemeManager.shared)
                )
                configurePanelForCurrentTheme(panel)
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.globalChannelWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.globalChannelWindow = panel
            }
        } else {
            globalChannelWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeGlobalChannelWindow() {
        globalChannelWindow?.close()
        globalChannelWindow = nil
    }

    // MARK: - FireWire Net Bridge Window

    func showFireWireNetBridgeWindow() {
        if fireWireNetBridgeWindow == nil {
            Task { @MainActor in
                let minW = FireWireNetBridgeRootView.preferredMinWidth
                let minH = FireWireNetBridgeRootView.preferredMinHeight
                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: minW, height: minH),
                    styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.title = "FireWire Net Bridge"
                panel.minSize = NSSize(width: minW, height: minH)
                panel.contentView = NSHostingView(rootView:
                    FireWireNetBridgeRootView()
                        .frame(minWidth: minW, minHeight: minH)
                )
                configurePanelForCurrentTheme(panel)
                panel.isMovableByWindowBackground = false
                self.registerLifecycle(for: panel) { [weak self] in
                    self?.fireWireNetBridgeWindow = nil
                }
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.fireWireNetBridgeWindow = panel
            }
        } else {
            fireWireNetBridgeWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func closeFireWireNetBridgeWindow() {
        fireWireNetBridgeWindow?.close()
        fireWireNetBridgeWindow = nil
    }
}

// MARK: - Hoverable Floating Meter View (iPhone Mirroring-style hover chrome)
struct HoverableFloatingMeterView<Content: View>: View {
    @EnvironmentObject var themeManager: ThemeManager
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovering = false
    @State private var isCloseHovering = false

    var body: some View {
        ZStack(alignment: .top) {
            // Theme background
            if themeManager.currentThemeMode == .liquidGlass {
                LiquidGlassBackground()
                    .edgesIgnoringSafeArea(.all)
            } else {
                themeManager.accentFillColor
                    .edgesIgnoringSafeArea(.all)
            }

            content
                .padding(12)

            HStack(spacing: 6) {
                Circle()
                    .fill(isCloseHovering ? Color.red : Color.red.opacity(0.75))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Image(systemName: "xmark")
                            .font(.system(size: 5.5, weight: .heavy))
                            .foregroundColor(Color.black.opacity(0.6))
                            .opacity(isCloseHovering ? 1 : 0)
                    )
                    .onHover { isCloseHovering = $0 }
                    .onTapGesture { onClose() }

                Spacer()

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                Circle().fill(.clear).frame(width: 12, height: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white.opacity(isHovering ? 0.12 : 0.0))
            .allowsHitTesting(isHovering)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct FloatingWindowHostingView<Content: View>: View {
    @EnvironmentObject var themeManager: ThemeManager
    let content: () -> Content
    var body: some View {
        ZStack {
            GlassBackground(.panel, cornerRadius: 14, shape: RoundedRectangle(cornerRadius: 14))
                .edgesIgnoringSafeArea(.all)
            content()
        }
    }
}
#endif
