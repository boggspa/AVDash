// File: PowerMetricsServiceClient.swift
// PodcastPreview
// App-side XPC client used to talk to the privileged helper via Mach service.

import Foundation
import os.log

public final class PowerMetricsServiceClient {
    private static let requestTimeout: TimeInterval = 7.0

    private let logger = Logger(subsystem: PowerMetricsServiceConstants.mainAppBundleID, category: "PowerMetricsServiceClient")
    private let stateQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.PowerMetricsServiceClient")
    private var connection: NSXPCConnection?

    public init() {}

    deinit {
        invalidate()
    }

    public var isSupportedAndAvailable: Bool {
        PowerMetricsServiceAvailability.isSupportedOS
    }

    public func invalidate() {
        let connectionToInvalidate = stateQueue.sync { () -> NSXPCConnection? in
            let existing = connection
            connection = nil
            return existing
        }
        connectionToInvalidate?.invalidate()
    }

    /// Connects to the helper and fetches one sample.
    public func fetchPowerMetricsSample(completion: @escaping (Data?) -> Void) {
        guard isSupportedAndAvailable else {
            completion(nil)
            return
        }

        let connection = currentConnection()
        let responseQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.PowerMetricsServiceClient.fetch")
        var finished = false

        @discardableResult
        func finish(_ data: Data?) -> Bool {
            responseQueue.sync {
                guard !finished else { return false }
                finished = true
                completion(data)
                return true
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("PowerMetrics XPC request failed: \(error.localizedDescription, privacy: .public)")
            if finish(nil) {
                self?.invalidate()
            }
        }) as? PowerMetricsXPCProtocol else {
            finish(nil)
            invalidate()
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard finish(nil) else { return }
            self?.logger.error("PowerMetrics XPC request timed out")
            self?.invalidate()
        }

        proxy.fetchPowerMetricsSample { data in
            finish(data)
        }
    }

    public func ping(completion: @escaping (Bool) -> Void) {
        guard isSupportedAndAvailable else {
            completion(false)
            return
        }

        let connection = currentConnection()
        let responseQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.PowerMetricsServiceClient.ping")
        var finished = false

        @discardableResult
        func finish(_ isReachable: Bool) -> Bool {
            responseQueue.sync {
                guard !finished else { return false }
                finished = true
                completion(isReachable)
                return true
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("PowerMetrics XPC ping failed: \(error.localizedDescription, privacy: .public)")
            if finish(false) {
                self?.invalidate()
            }
        }) as? PowerMetricsXPCProtocol else {
            finish(false)
            invalidate()
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard finish(false) else { return }
            self?.logger.error("PowerMetrics XPC ping timed out")
            self?.invalidate()
        }

        proxy.ping { response in
            finish(response == "pong")
        }
    }

    public func fetchHealth(completion: @escaping (PowerMetricsHealthSnapshot?) -> Void) {
        guard isSupportedAndAvailable else {
            completion(nil)
            return
        }

        let connection = currentConnection()
        let responseQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.PowerMetricsServiceClient.health")
        var finished = false
        let decoder = PropertyListDecoder()

        @discardableResult
        func finish(_ snapshot: PowerMetricsHealthSnapshot?) -> Bool {
            responseQueue.sync {
                guard !finished else { return false }
                finished = true
                completion(snapshot)
                return true
            }
        }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.logger.error("PowerMetrics XPC health failed: \(error.localizedDescription, privacy: .public)")
            if finish(nil) {
                self?.invalidate()
            }
        }) as? PowerMetricsXPCProtocol else {
            finish(nil)
            invalidate()
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard finish(nil) else { return }
            self?.logger.error("PowerMetrics XPC health timed out")
            self?.invalidate()
        }

        proxy.fetchHealth { data in
            guard let data,
                  let snapshot = try? decoder.decode(PowerMetricsHealthSnapshot.self, from: data) else {
                finish(nil)
                return
            }
            finish(snapshot)
        }
    }

    private func currentConnection() -> NSXPCConnection {
        stateQueue.sync {
            if let connection {
                return connection
            }

            let connection = NSXPCConnection(
                machServiceName: PowerMetricsServiceConstants.activeMachServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: PowerMetricsXPCProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection {
                        self.connection = nil
                    }
                }
                self.logger.error("PowerMetrics XPC connection invalidated")
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection {
                        self.connection = nil
                    }
                }
                self.logger.error("PowerMetrics XPC connection interrupted")
            }
            connection.resume()
            self.connection = connection
            return connection
        }
    }
}
