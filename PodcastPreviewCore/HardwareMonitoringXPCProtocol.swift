import Foundation

@objc public protocol HardwareMonitoringXPCProtocol {
    func fetchStatus(_ reply: @escaping (Data?) -> Void)
    func startMonitoring(_ reply: @escaping (Data?) -> Void)
    func stopMonitoring(_ reply: @escaping (Data?) -> Void)
    func setCollectionProfile(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchCollectorSnapshot(_ reply: @escaping (Data?) -> Void)
    func fetchPollingSnapshot(_ reply: @escaping (Data?) -> Void)
    func fetchDashboardFrame(_ reply: @escaping (Data?) -> Void)
    func fetchLatestTelemetryFrame(_ reply: @escaping (Data?) -> Void)
    func fetchAvailableDevices(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchMetricTimeline(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchDeviceMetricTimeline(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchMetricInsight(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchDeviceMetricInsight(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchProcessTimeline(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchProcessSummary(_ requestData: Data, reply: @escaping (Data?) -> Void)
    func fetchEvents(_ requestData: Data, reply: @escaping (Data?) -> Void)
}
