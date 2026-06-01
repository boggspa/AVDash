import Foundation
import PodcastPreviewCore
import ServiceManagement
import os.log

final class HardwareMonitoringServiceClient {
    private static let liveRequestTimeout: TimeInterval = 4.0
    private static let collectorSnapshotRequestTimeout: TimeInterval = 12.0
    private static let historyRequestTimeout: TimeInterval = 20.0

    private let logger = Logger(
        subsystem: HardwareMonitoringServiceConstants.mainAppBundleID,
        category: "HardwareMonitoringServiceClient"
    )
    private let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()
    private let decoder = PropertyListDecoder()
    private var connection: NSXPCConnection?
    private let stateQueue = DispatchQueue(label: "HardwareMonitoringServiceClient.state")
    private let legacyDescriptor = LegacyUserLaunchAgentDescriptor(
        plistName: HardwareMonitoringServiceConstants.legacyLaunchAgentPlistName,
        label: HardwareMonitoringServiceConstants.legacyLaunchAgentLabel,
        helperExecutableName: HardwareMonitoringServiceConstants.legacyLaunchAgentHelperExecutableName
    )

    private var activeMachServiceName: String {
        if HardwareMonitoringServiceAvailability.usesSMAppServiceDaemon {
            return HardwareMonitoringServiceConstants.modernMachServiceName
        }
        if HardwareMonitoringServiceAvailability.usesLegacyPrivilegedHelper {
            return HardwareMonitoringServiceConstants.legacyMachServiceName
        }
        return HardwareMonitoringServiceConstants.legacyLaunchAgentLabel
    }

    var isSupportedPlatform: Bool {
        HardwareMonitoringServiceAvailability.isSupportedOS
    }

    var isSupportedAndAvailable: Bool {
        HardwareMonitoringServiceAvailability.isSupportedOS
    }

    func isServiceReachableSynchronously(timeout: TimeInterval = 0.5) -> Bool {
        guard isSupportedAndAvailable else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var isReachable = false

        fetchStatus { snapshot in
            isReachable = snapshot != nil
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return isReachable
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    func fetchStatus(completion: @escaping (HardwareCollectorStatusSnapshot?) -> Void) {
        performDecodedRequest(completion: completion) { proxy, reply in
            proxy.fetchStatus(reply)
        }
    }

    func startMonitoring(completion: @escaping (HardwareCollectorStatusSnapshot?) -> Void) {
        performDecodedRequest(completion: completion) { proxy, reply in
            proxy.startMonitoring(reply)
        }
    }

    func stopMonitoring(completion: @escaping (HardwareCollectorStatusSnapshot?) -> Void) {
        performDecodedRequest(completion: completion) { proxy, reply in
            proxy.stopMonitoring(reply)
        }
    }

    func setCollectionProfile(
        _ profile: HardwareCollectionProfile,
        completion: @escaping (HardwareCollectorStatusSnapshot?) -> Void
    ) {
        let request = HardwareCollectionProfileRequest(profile: profile)
        send(request, completion: completion) { proxy, data, reply in
            proxy.setCollectionProfile(data, reply: reply)
        }
    }

    func fetchLatestTelemetryFrame(completion: @escaping (HardwareTelemetryFrame?) -> Void) {
        performDecodedRequest(completion: completion) { proxy, reply in
            proxy.fetchLatestTelemetryFrame(reply)
        }
    }

    func fetchCollectorSnapshot(completion: @escaping (HardwareCollectorLiveSnapshot?) -> Void) {
        performDecodedRequest(timeout: Self.collectorSnapshotRequestTimeout, completion: completion) { proxy, reply in
            proxy.fetchCollectorSnapshot(reply)
        }
    }

    func fetchPollingSnapshot(completion: @escaping (HardwareCollectorPollingSnapshot?) -> Void) {
        performDecodedRequest(completion: completion) { proxy, reply in
            proxy.fetchPollingSnapshot(reply)
        }
    }

    func fetchDashboardFrame(completion: @escaping (HardwareDashboardFrame?) -> Void) {
        performDecodedRequest(completion: completion) { proxy, reply in
            proxy.fetchDashboardFrame(reply)
        }
    }

    func fetchAvailableDevices(
        deviceKind: HardwareDeviceKind? = nil,
        in range: DateInterval,
        completion: @escaping ([HardwareHistoryDeviceIdentity]?) -> Void
    ) {
        let request = HardwareAvailableDevicesRequest(
            deviceKind: deviceKind,
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end)
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchAvailableDevices(data, reply: reply)
        }
    }

    func fetchMetricTimeline(
        for key: HardwareMetricKey,
        in range: DateInterval,
        bucketIntervalSeconds: Int = 60,
        completion: @escaping ([HardwareHistoryMetricBucket]?) -> Void
    ) {
        let request = HardwareMetricTimelineRequest(
            key: key,
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end),
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchMetricTimeline(data, reply: reply)
        }
    }

    func fetchDeviceMetricTimeline(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        bucketIntervalSeconds: Int = 60,
        completion: @escaping ([HardwareHistoryMetricBucket]?) -> Void
    ) {
        let request = HardwareDeviceMetricTimelineRequest(
            key: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end),
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchDeviceMetricTimeline(data, reply: reply)
        }
    }

    func fetchMetricInsight(
        for key: HardwareMetricKey,
        in range: DateInterval,
        summaryBucketIntervalSeconds: Int = 3600,
        completion: @escaping (HardwareMetricInsight?) -> Void
    ) {
        let request = HardwareMetricInsightRequest(
            key: key,
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end),
            summaryBucketIntervalSeconds: summaryBucketIntervalSeconds
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchMetricInsight(data, reply: reply)
        }
    }

    /// Uses the same tiered summary bucket widths as ``HardwareInsightsService`` (via ``HardwareInsightWindow/insightSummaryBucketIntervalSeconds``).
    func fetchMetricInsight(
        for key: HardwareMetricKey,
        window: HardwareInsightWindow,
        anchorDate: Date = Date(),
        completion: @escaping (HardwareMetricInsight?) -> Void
    ) {
        let range = window.range(anchoredAt: anchorDate)
        fetchMetricInsight(
            for: key,
            in: range,
            summaryBucketIntervalSeconds: window.insightSummaryBucketIntervalSeconds,
            completion: completion
        )
    }

    func fetchDeviceMetricInsight(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        summaryBucketIntervalSeconds: Int = 3600,
        completion: @escaping (HardwareMetricInsight?) -> Void
    ) {
        let request = HardwareDeviceMetricInsightRequest(
            key: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end),
            summaryBucketIntervalSeconds: summaryBucketIntervalSeconds
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchDeviceMetricInsight(data, reply: reply)
        }
    }

    func fetchDeviceMetricInsight(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        window: HardwareInsightWindow,
        anchorDate: Date = Date(),
        completion: @escaping (HardwareMetricInsight?) -> Void
    ) {
        let range = window.range(anchoredAt: anchorDate)
        fetchDeviceMetricInsight(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            summaryBucketIntervalSeconds: window.insightSummaryBucketIntervalSeconds,
            completion: completion
        )
    }

    func fetchProcessTimeline(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int = 3600,
        completion: @escaping ([ProcessHistoryBucket]?) -> Void
    ) {
        let request = HardwareProcessTimelineRequest(
            identity: identity,
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end),
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchProcessTimeline(data, reply: reply)
        }
    }

    func fetchProcessSummary(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int = 3600,
        completion: @escaping (ProcessHistorySummary?) -> Void
    ) {
        let request = HardwareProcessSummaryRequest(
            identity: identity,
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end),
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchProcessSummary(data, reply: reply)
        }
    }

    func fetchEvents(
        in range: DateInterval,
        categories: [HardwareEventCategory]? = nil,
        limit: Int = 96,
        completion: @escaping ([HardwareTimelineEvent]?) -> Void
    ) {
        let request = HardwareEventsRequest(
            range: HardwareMonitoringQueryRange(start: range.start, end: range.end),
            categories: categories,
            limit: limit
        )
        send(request, completion: completion) { proxy, data, reply in
            proxy.fetchEvents(data, reply: reply)
        }
    }

    private func send<Request: Encodable, Reply: Decodable>(
        _ request: Request,
        completion: @escaping (Reply?) -> Void,
        operation: (HardwareMonitoringXPCProtocol, Data, @escaping (Data?) -> Void) -> Void
    ) {
        guard isSupportedAndAvailable else {
            completion(nil)
            return
        }

        guard let data = try? encoder.encode(request) else {
            completion(nil)
            return
        }

        performDecodedRequest(timeout: Self.historyRequestTimeout, completion: completion) { proxy, reply in
            operation(proxy, data, reply)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func performDecodedRequest<Reply: Decodable>(
        timeout: TimeInterval = HardwareMonitoringServiceClient.liveRequestTimeout,
        completion: @escaping (Reply?) -> Void,
        operation: (HardwareMonitoringXPCProtocol, @escaping (Data?) -> Void) -> Void
    ) {
        guard isSupportedAndAvailable else {
            completion(nil)
            return
        }

        let connection = ensureConnection()
        let finishQueue = DispatchQueue(label: "HardwareMonitoringServiceClient.request")
        var finished = false

        @discardableResult
        func finish(_ value: Reply?) -> Bool {
            finishQueue.sync {
                guard !finished else { return false }
                finished = true
                completion(value)
                return true
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("Hardware monitoring XPC error: \(String(describing: error as NSError))")
            if finish(nil) {
                self?.resetConnection(connection)
            }
        }) as? HardwareMonitoringXPCProtocol else {
            finish(nil)
            resetConnection(connection)
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard finish(nil) else { return }
            self?.logger.error("Hardware monitoring XPC request timed out after \(timeout, format: .fixed(precision: 1))s")
            self?.resetConnection(connection)
        }

        operation(proxy) { [weak self] data in
            guard let self else {
                finish(nil)
                return
            }
            finish(self.decode(Reply.self, from: data))
        }
    }

    private func remoteProxy(completion: @escaping () -> Void) -> HardwareMonitoringXPCProtocol? {
        let connection = ensureConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.logger.error("Hardware monitoring XPC error: \(String(describing: error as NSError))")
            self?.resetConnection(connection)
            completion()
        }
        return proxy as? HardwareMonitoringXPCProtocol
    }

    private func ensureConnection() -> NSXPCConnection {
        stateQueue.sync {
            if let connection {
                return connection
            }

            let connection: NSXPCConnection
            if HardwareMonitoringServiceAvailability.usesSMAppServiceDaemon
                || HardwareMonitoringServiceAvailability.usesLegacyPrivilegedHelper {
                connection = NSXPCConnection(
                    machServiceName: activeMachServiceName,
                    options: .privileged
                )
            } else {
                connection = NSXPCConnection(machServiceName: activeMachServiceName)
            }
            connection.remoteObjectInterface = NSXPCInterface(with: HardwareMonitoringXPCProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection { self.connection = nil }
                }
                self.logger.error("Hardware monitoring XPC connection invalidated")
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection { self.connection = nil }
                }
                self.logger.error("Hardware monitoring XPC connection interrupted")
            }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    private func resetConnection(_ staleConnection: NSXPCConnection?) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard let staleConnection else {
                self.connection = nil
                return
            }
            if self.connection === staleConnection {
                staleConnection.invalidate()
                self.connection = nil
            }
        }
    }
}
