import Foundation
import PodcastPreviewCore

enum AppGPUUsageProvider {
    static let live = HardwareAppGPUUsageProvider {
        MetalGPUStatsCollector.shared.consumePercentSinceLastSample()
    }
}
