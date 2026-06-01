import Foundation
import PodcastPreviewCore

enum AppPowerMetricsProvider {
    private static let client = PowerMetricsServiceClient()

    static let live = HardwarePowerMetricsProvider { completion in
        if #available(macOS 11.0, *) {
            Task { @MainActor in
                client.fetchPowerMetricsSample { data in
                    completion(data)
                }
            }
        } else {
            completion(nil)
        }
    }
}
