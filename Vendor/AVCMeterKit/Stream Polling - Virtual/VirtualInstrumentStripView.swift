import CoreAudio
import SwiftUI

struct VirtualInstrumentStripView: View {
    @EnvironmentObject var themeManager: ThemeManager
    let deviceID: AudioDeviceID
    let channelIndex: Int

    var body: some View {
        if let context = AudioDeviceManager.shared.activeDevices[deviceID] {
            if RenderBackendResolver.resolveMeterBackend() == .cpu {
                CPUCapsuleBarView(
                    context: context,
                    channelIndex: channelIndex,
                    themeMode: themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode
                )
                .frame(width: 12.8, height: 280)
            } else {
                MetalCapsuleWithText(
                    context: context,
                    channelIndex: channelIndex,
                    showsFeatureIcons: false,
                    showsLevelTexts: false,
                    channelHeaderYOffset: 32,
                    channelHeaderYOffsetCPU: 32,
                    capsuleYOffset: -48
                )
                .environmentObject(themeManager)
                .frame(width: 12.8, height: 280)
            }
        } else {
            EmptyView()
        }
    }
}
