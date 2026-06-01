import Foundation
import ServiceManagement
import os.log

final class AudioRoutingServiceClient {
    private let logger = Logger(subsystem: AudioRoutingServiceConstants.mainAppBundleID, category: "AudioRoutingServiceClient")
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private var connection: NSXPCConnection?
    private let stateQueue = DispatchQueue(label: "AudioRoutingServiceClient.state")
    private let legacyDescriptor = LegacyUserLaunchAgentDescriptor(
        plistName: AudioRoutingServiceConstants.launchAgentPlistName,
        label: AudioRoutingServiceConstants.helperBundleID,
        helperExecutableName: "PodcastPreviewAudioAgent"
    )

    var isSupportedPlatform: Bool {
        LegacyUserLaunchAgentSupport.isSupportedOnCurrentOS
    }

    var isSupportedAndAvailable: Bool {
        return LegacyUserLaunchAgentSupport.isInstalled(for: legacyDescriptor)
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        connection?.invalidate()
        connection = nil
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

    func fetchStatus(completion: @escaping (AudioRoutingStatusSnapshot?) -> Void) {
        guard isSupportedAndAvailable else {
            completion(nil)
            return
        }

        guard let proxy = remoteProxy(completion: { completion(nil) }) else {
            return
        }

        proxy.fetchStatus { [weak self] data in
            guard let self, let data else {
                completion(nil)
                return
            }

            completion(try? self.decoder.decode(AudioRoutingStatusSnapshot.self, from: data))
        }
    }

    func setConfiguration(_ configuration: AudioRoutingConfiguration,
                          completion: @escaping (AudioRoutingStatusSnapshot?) -> Void) {
        guard isSupportedAndAvailable else {
            completion(nil)
            return
        }

        guard let data = try? encoder.encode(configuration) else {
            completion(nil)
            return
        }

        guard let proxy = remoteProxy(completion: { completion(nil) }) else {
            return
        }

        proxy.setConfiguration(data) { [weak self] response in
            guard let self, let response else {
                completion(nil)
                return
            }

            completion(try? self.decoder.decode(AudioRoutingStatusSnapshot.self, from: response))
        }
    }

    func fetchTapSnapshot(maxFrames: Int,
                          completion: @escaping (AudioRoutingTapSnapshot?) -> Void) {
        guard isSupportedAndAvailable else {
            completion(nil)
            return
        }

        guard let proxy = remoteProxy(completion: { completion(nil) }) else {
            return
        }

        proxy.fetchTapSnapshot(NSNumber(value: maxFrames)) { [weak self] response in
            guard let self, let response else {
                completion(nil)
                return
            }

            completion(try? self.decoder.decode(AudioRoutingTapSnapshot.self, from: response))
        }
    }

    private func remoteProxy(completion: @escaping () -> Void) -> AudioRoutingXPCProtocol? {
        let connection = ensureConnection()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.logger.error("Audio routing XPC error: \(String(describing: error as NSError))")
            self?.resetConnection(connection)
            completion()
        }
        return proxy as? AudioRoutingXPCProtocol
    }

    private func ensureConnection() -> NSXPCConnection {
        stateQueue.sync {
            if let connection {
                return connection
            }

            let connection = NSXPCConnection(machServiceName: AudioRoutingServiceConstants.machServiceName)
            connection.remoteObjectInterface = NSXPCInterface(with: AudioRoutingXPCProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection { self.connection = nil }
                }
                self.logger.error("Audio routing XPC connection invalidated")
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.stateQueue.async {
                    if self.connection === connection { self.connection = nil }
                }
                self.logger.error("Audio routing XPC connection interrupted")
            }
            connection.resume()
            self.connection = connection
            return connection
        }
    }
}
