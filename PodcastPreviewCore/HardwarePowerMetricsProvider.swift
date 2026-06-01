import Foundation

public struct HardwarePowerMetricsProvider: Sendable {
    private let fetchSampleHandler: @Sendable (@escaping @Sendable (Data?) -> Void) -> Void

    public init(
        fetchSampleHandler: @escaping @Sendable (@escaping @Sendable (Data?) -> Void) -> Void
    ) {
        self.fetchSampleHandler = fetchSampleHandler
    }

    public func fetchPowerMetricsSample(completion: @escaping @Sendable (Data?) -> Void) {
        fetchSampleHandler(completion)
    }
}
