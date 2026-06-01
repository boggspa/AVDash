import Foundation
import SwiftUI
#if INCLUDE_AVCMETERKIT && canImport(AVCMeterKit)
import AVCMeterKit
#endif

private enum LegacyAudioSpectrumSource: String, CaseIterable, Identifiable {
    case input
    case output

    var id: String { rawValue }

    var label: String {
        switch self {
        case .input:
            return "Input"
        case .output:
            return "Output"
        }
    }
}

struct PodcastPreviewAudioTabView: View {
    @AppStorage("audio.useAVCMeterKit") private var useAVCMeterKit: Bool = true

    #if INCLUDE_AVCMETERKIT && canImport(AVCMeterKit)
    private let avcMeterConfiguration = AVCMeterConfiguration(themeMode: .mapped)
    #endif

    var body: some View {
        Group {
            #if INCLUDE_AVCMETERKIT && canImport(AVCMeterKit)
            if useAVCMeterKit {
                ZStack(alignment: .bottom) {
                    AVCMeterRootView(configuration: avcMeterConfiguration)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    VirtualCameraRuntimeHealthToolbar(sectionTitle: "Virtual Camera")
                }
                .onAppear {
                        #if DEBUG
                        NSLog("PodcastPreview audio tab mounted: AVCMeterKit")
                        #endif
                    }
                    .onDisappear {
                        #if DEBUG
                        NSLog("PodcastPreview audio tab unmounted: AVCMeterKit")
                        #endif
                    }
            }
            #else
            LegacyPodcastPreviewAudioTabView()
            #endif
            #if INCLUDE_AVCMETERKIT && canImport(AVCMeterKit)
            if !useAVCMeterKit {
                LegacyPodcastPreviewAudioTabView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .onAppear {
                        #if DEBUG
                        NSLog("PodcastPreview audio tab mounted: legacy")
                        #endif
                    }
                    .onDisappear {
                        #if DEBUG
                        NSLog("PodcastPreview audio tab unmounted: legacy")
                        #endif
                    }
            }
            #endif
        }
    }
}

private struct LegacyPodcastPreviewAudioTabView: View {
    @Environment(\.appUIScale) private var appUIScale
    @StateObject private var monitoring = MonitoringState(autoRefreshDevices: false)
    @StateObject private var multiDeviceManager = MultiDeviceAudioManager()
    @StateObject private var virtualLoopback = VirtualLoopbackModel()

    @State private var fftSize: Int = 1024
    @State private var spectrumDecay: SpectrumView.DecayOption = .medium
    @State private var spectrumFreqRange: SpectrumView.FrequencyRangePreset = .fullRange
    @State private var audioSpectrumSource: LegacyAudioSpectrumSource = .input
    @State private var waveformHistoryDuration: TimeInterval = 2.0

    private var hasInputSpectrumSource: Bool {
        multiDeviceManager.spectrumDevice != nil && multiDeviceManager.spectrumMonitoringState != nil
    }

    private var hasOutputSpectrumSource: Bool {
        virtualLoopback.isTapSpectrumAvailable
    }

    var body: some View {
        // ... (legacy view implementation)
        Text("Legacy Audio Tab")
    }
}
