import AppKit
import SwiftUI

public struct AVCMeterRootView: View {
    private let configuration: AVCMeterConfiguration
    private let minimumWidth: CGFloat
    private let minimumHeight: CGFloat

    @StateObject private var themeManager: ThemeManager
    @StateObject private var deviceManager: AudioDeviceManager
    @StateObject private var bridgeManager: AudioBridgeManager
    @StateObject private var outputManager: OutputDeviceManager
    @StateObject private var matrixManager: AudioRoutingMatrixManager
    @StateObject private var virtualChannelManager: VirtualChannelManager
    @StateObject private var midiManager: MIDIStateManager
    @StateObject private var session: AVCMeterSession

    public init(configuration: AVCMeterConfiguration = .init()) {
        self.configuration = configuration

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        minimumWidth = configuration.minimumWindowSize.width / (4.0 / scale)
        minimumHeight = configuration.minimumWindowSize.height / (4.0 / scale)

        let themeManager = ThemeManager()
        themeManager.isEmbeddedInHost = configuration.themeMode == .mapped
        if configuration.themeMode == .mapped {
            themeManager.currentThemeMode = .graphite
            themeManager.capsuleThemeMode = .graphite
            themeManager.accentColor = NSColor.gray.withAlphaComponent(0.45)
        }

        _themeManager = StateObject(wrappedValue: themeManager)
        _deviceManager = StateObject(wrappedValue: AudioDeviceManager.shared)
        _bridgeManager = StateObject(wrappedValue: AudioBridgeManager.shared)
        _outputManager = StateObject(wrappedValue: OutputDeviceManager.shared)
        _matrixManager = StateObject(wrappedValue: AudioRoutingMatrixManager(syncedInputs: [:], syncedOutputs: [:]))
        _virtualChannelManager = StateObject(wrappedValue: VirtualChannelManager.shared)
        _midiManager = StateObject(wrappedValue: MIDIStateManager())
        _session = StateObject(wrappedValue: AVCMeterSession(configuration: configuration))
    }

    public var body: some View {
        ContentView()
            .environmentObject(themeManager)
            .environmentObject(deviceManager)
            .environmentObject(outputManager)
            .environmentObject(bridgeManager)
            .environmentObject(virtualChannelManager)
            .environmentObject(midiManager)
            .environmentObject(matrixManager)
            .frame(minWidth: minimumWidth, minHeight: minimumHeight)
            .onAppear {
                session.start()
            }
            .onDisappear {
                session.stop()
            }
    }
}
