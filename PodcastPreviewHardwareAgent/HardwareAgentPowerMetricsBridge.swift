import Foundation
import os.log
#if !HARDWARE_JOBBLESS_EMBEDS_CORE
import PodcastPreviewCore
#endif

@objc private protocol HardwareAgentPowerMetricsXPCProtocol {
    func fetchPowerMetricsSample(withReply reply: @escaping (Data?) -> Void)
}

private enum HardwareAgentPowerMetricsConstants {
    static var machServiceName: String {
        if #available(macOS 13.0, *) {
            return "com.chrisizatt.PodcastPreview.PowerMetricsService"
        }
        return "com.chrisizatt.PodcastPreview.PowerMetricsJobBless"
    }

    static let loggingSubsystem = "com.chrisizatt.PodcastPreview.HardwareAgent.PowerMetrics"
}

private final class HardwareAgentPowerMetricsServiceClient {
    private static let requestTimeout: TimeInterval = 7.0

    private let logger = Logger(
        subsystem: HardwareAgentPowerMetricsConstants.loggingSubsystem,
        category: "Client"
    )
    private let stateQueue = DispatchQueue(
        label: "com.chrisizatt.PodcastPreview.HardwareAgent.PowerMetricsClient"
    )
    private var connection: NSXPCConnection?

    func invalidate() {
        let staleConnection = stateQueue.sync { () -> NSXPCConnection? in
            let existing = connection
            connection = nil
            return existing
        }
        staleConnection?.invalidate()
    }

    func fetchPowerMetricsSample(completion: @escaping @Sendable (Data?) -> Void) {
        let connection = currentConnection()
        let responseQueue = DispatchQueue(
            label: "com.chrisizatt.PodcastPreview.HardwareAgent.PowerMetricsClient.fetch"
        )
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
            self?.logger.error("Power metrics XPC request failed: \(error.localizedDescription, privacy: .public)")
            if finish(nil) {
                self?.invalidate()
            }
        }) as? HardwareAgentPowerMetricsXPCProtocol else {
            finish(nil)
            invalidate()
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            guard finish(nil) else { return }
            self?.logger.error("Power metrics XPC request timed out")
            self?.invalidate()
        }

        proxy.fetchPowerMetricsSample { data in
            finish(data)
        }
    }

    private func currentConnection() -> NSXPCConnection {
        stateQueue.sync {
            if let connection {
                return connection
            }

            let connection = NSXPCConnection(
                machServiceName: HardwareAgentPowerMetricsConstants.machServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: HardwareAgentPowerMetricsXPCProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection {
                        self.connection = nil
                    }
                }
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection {
                        self.connection = nil
                    }
                }
            }
            connection.resume()
            self.connection = connection
            return connection
        }
    }
}

enum HardwareAgentPowerMetricsProvider {
    private static let client = HardwareAgentPowerMetricsServiceClient()

    static let live = HardwarePowerMetricsProvider { completion in
        client.fetchPowerMetricsSample(completion: completion)
    }
}
