import Foundation

public struct HardwareAppGPUUsageProvider: Sendable {
    private let currentUsageHandler: @Sendable () -> Double?

    public init(currentUsageHandler: @escaping @Sendable () -> Double?) {
        self.currentUsageHandler = currentUsageHandler
    }

    public func currentUsagePercent() -> Double? {
        currentUsageHandler()
    }
}
