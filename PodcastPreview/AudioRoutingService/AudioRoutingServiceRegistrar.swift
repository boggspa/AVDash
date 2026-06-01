import Foundation
import ServiceManagement
import os.log

final class AudioRoutingServiceRegistrar {
    private let logger = Logger(subsystem: AudioRoutingServiceConstants.mainAppBundleID, category: "AudioRoutingServiceRegistrar")
    private let legacyDescriptor = LegacyUserLaunchAgentDescriptor(
        plistName: AudioRoutingServiceConstants.launchAgentPlistName,
        label: AudioRoutingServiceConstants.helperBundleID,
        helperExecutableName: "PodcastPreviewAudioAgent"
    )

    func registerIfNeeded(
        forceRefresh: Bool = false,
        completion: @escaping (Result<Void, AudioRoutingClientError>) -> Void
    ) {
        guard LegacyUserLaunchAgentSupport.isSupportedOnCurrentOS else {
            completion(.failure(.unavailable))
            return
        }

        if !forceRefresh,
           LegacyUserLaunchAgentSupport.isInstalled(for: legacyDescriptor),
           userLaunchAgentResponds() {
            logger.debug("Audio routing launch agent already installed and reachable")
            completion(.success(()))
            return
        }

        if forceRefresh {
            do {
                _ = try LegacyUserLaunchAgentSupport.unregisterIfPresent(
                    legacyDescriptor,
                    allowOnModernOS: true
                )
            } catch {
                logger.warning("Audio routing launch agent unregister during refresh failed: \(String(describing: error as NSError))")
            }
        }

        unregisterSMAppServiceIfPresent()

        do {
            try LegacyUserLaunchAgentSupport.registerOrRefresh(
                legacyDescriptor,
                allowOnModernOS: true
            )
            logger.debug("Audio routing launch agent installed via user LaunchAgent path")
            completion(.success(()))
        } catch {
            logger.error("Failed to install audio routing launch agent: \(String(describing: error as NSError))")
            completion(.failure(.registrationFailed))
        }
    }

    func unregister(completion: @escaping (Result<Void, AudioRoutingClientError>) -> Void) {
        var removalFailed = false

        if LegacyUserLaunchAgentSupport.isSupportedOnCurrentOS {
            do {
                _ = try LegacyUserLaunchAgentSupport.unregisterIfPresent(
                    legacyDescriptor,
                    allowOnModernOS: true
                )
                logger.debug("Audio routing launch agent removed via user LaunchAgent path")
            } catch {
                removalFailed = true
                logger.error("Failed to remove user audio routing launch agent: \(String(describing: error as NSError))")
            }
        }

        if !unregisterSMAppServiceIfPresent() {
            removalFailed = true
        }

        completion(removalFailed ? .failure(.registrationFailed) : .success(()))
    }

    @discardableResult
    private func unregisterSMAppServiceIfPresent() -> Bool {
        guard #available(macOS 13.0, *) else {
            return true
        }

        let service = SMAppService.agent(plistName: AudioRoutingServiceConstants.launchAgentPlistName)
        do {
            try service.unregister()
            logger.debug("Stale SMAppService audio routing launch agent unregistered")
            return true
        } catch {
            logger.warning("SMAppService audio routing launch agent unregister skipped or failed: \(String(describing: error as NSError))")
            return true
        }
    }

    private func userLaunchAgentResponds(timeout: TimeInterval = 1.25) -> Bool {
        let client = AudioRoutingServiceClient()
        let semaphore = DispatchSemaphore(value: 0)
        var didRespond = false

        client.fetchStatus { snapshot in
            didRespond = snapshot != nil
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            client.invalidate()
            return false
        }
        return didRespond
    }
}
