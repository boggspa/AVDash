// File: PowerMetricsServiceRegistrar.swift
// PodcastPreview
// App-side registrar for privileged helper daemon with dual-path support:
// - macOS 13+: SMAppService
// - macOS 11-12: SMJobBless

import Foundation
import ServiceManagement
import Security
import os.log

public final class PowerMetricsServiceRegistrar {
    private static let modernHelperStartupRetryDelays: [TimeInterval] = [0.0, 0.25, 0.75, 1.5, 3.0]
    private static let modernHelperStartupTimeout: TimeInterval = 7.0
    private static let legacyHelperStartupRetryDelays: [TimeInterval] = [0.0, 0.25, 0.75, 1.5, 3.0]
    private static let legacyHelperStartupTimeout: TimeInterval = 7.0

    private let logger = Logger(subsystem: PowerMetricsServiceConstants.mainAppBundleID, category: "PowerMetricsServiceRegistrar")

    public init() {}
    
    // MARK: - Debug Console Logging
    
    private func logToConsole(_ message: String, level: String = "INFO") {
        // Debug console logging temporarily disabled
        // #if DEBUG && canImport(SwiftUI)
        // Task { @MainActor in
        //     AppDebugConsole.log("[\(level)] \(message)", category: "PowerMetrics")
        // }
        // #endif
    }

    /// Registers the daemon with launchd, using the appropriate method for the OS version.
    /// - macOS 13+: Uses SMAppService (modern)
    /// - macOS 11-12: Uses SMJobBless (legacy)
    /// - macOS 10.x: Returns .unavailable
    public func registerIfNeeded(
        forceRefresh: Bool = false,
        completion: @escaping (Result<Void, PowerMetricsClientError>) -> Void
    ) {
        guard PowerMetricsServiceAvailability.isSupportedOS else {
            completion(.failure(.unavailable))
            return
        }

        // Modern path: macOS 13+
        if #available(macOS 13.0, *) {
            registerWithSMAppService(forceRefresh: forceRefresh, completion: completion)
        }
        // Legacy path: macOS 11-12
        else {
            DispatchQueue.global(qos: .utility).async {
                if !forceRefresh, self.ensureLegacyHelperReady() {
                    self.logger.debug("Power metrics privileged helper already reachable")
                    completion(.success(()))
                    return
                }

                let forceReplaceExisting = forceRefresh || PowerMetricsServiceAvailability.isLegacyPrivilegedHelperInstalled
                if forceReplaceExisting {
                    self.logger.warning("Installed legacy power metrics helper is unreachable, forcing helper replacement")
                    self.logToConsole("Installed legacy power metrics helper is unreachable, forcing helper replacement", level: "WARN")
                }

                self.registerWithSMJobBless(
                    forceReplaceExisting: forceReplaceExisting,
                    completion: completion
                )
            }
        }
    }

    public func unregister(completion: @escaping (Result<Void, PowerMetricsClientError>) -> Void) {
        guard PowerMetricsServiceAvailability.isSupportedOS else {
            completion(.failure(.unavailable))
            return
        }

        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: PowerMetricsServiceConstants.modernDaemonPlistName)
            do {
                try service.unregister()
                logger.debug("PowerMetricsService daemon unregistered")
                completion(.success(()))
            } catch {
                logger.error("Failed to unregister PowerMetricsService daemon: \(String(describing: error as NSError))")
                completion(.failure(.connectionFailed))
            }
            return
        }

        DispatchQueue.global(qos: .utility).async {
            var authRef: AuthorizationRef?
            let authFlags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
            let authStatus: OSStatus = kSMRightBlessPrivilegedHelper.withCString { blessRightName in
                var authItem = AuthorizationItem(
                    name: blessRightName,
                    valueLength: 0,
                    value: nil,
                    flags: 0
                )

                return withUnsafeMutablePointer(to: &authItem) { authItemPointer in
                    var authRights = AuthorizationRights(count: 1, items: authItemPointer)
                    return AuthorizationCreate(&authRights, nil, authFlags, &authRef)
                }
            }

            guard authStatus == errAuthorizationSuccess, let authRef else {
                self.logger.error("Failed to create authorization reference for PowerMetricsService removal: \(authStatus)")
                completion(.failure(.connectionFailed))
                return
            }

            defer { AuthorizationFree(authRef, []) }

            guard PowerMetricsServiceAvailability.isLegacyPrivilegedHelperInstalled else {
                completion(.success(()))
                return
            }

            var cfError: Unmanaged<CFError>?
            let removed = SMJobRemove(
                kSMDomainSystemLaunchd,
                PowerMetricsServiceConstants.legacyHelperBundleID as CFString,
                authRef,
                true,
                &cfError
            )

            guard removed else {
                let error = cfError?.takeRetainedValue()
                self.logger.error("Failed to remove PowerMetricsService legacy helper: \(String(describing: error))")
                completion(.failure(.connectionFailed))
                return
            }

            self.logger.debug("PowerMetricsService legacy helper removed via SMJobRemove")
            completion(.success(()))
        }
    }

    // MARK: - Modern Registration (macOS 13+)
    
    @available(macOS 13.0, *)
    private func registerWithSMAppService(
        forceRefresh: Bool,
        completion: @escaping (Result<Void, PowerMetricsClientError>) -> Void
    ) {
        let service = SMAppService.daemon(plistName: PowerMetricsServiceConstants.modernDaemonPlistName)
        
        do {
            // Check current status
            switch service.status {
            case .enabled:
                if forceRefresh {
                    logger.debug("SMAppService daemon refresh was explicitly requested")
                    logToConsole("SMAppService daemon refresh was explicitly requested")
                    refreshModernDaemon(service, completion: completion)
                    return
                }
                logger.debug("SMAppService daemon already enabled, verifying daemon health")
                logToConsole("SMAppService daemon already enabled, verifying daemon health")
                verifyEnabledDaemonRegistration(service, completion: completion)
                return
            case .requiresApproval:
                logger.warning("SMAppService requires user approval in System Settings")
                logToConsole("SMAppService requires user approval in System Settings", level: "WARN")
                // Still attempt registration to trigger approval dialog
            case .notRegistered:
                logger.debug("SMAppService not registered, attempting registration")
                logToConsole("SMAppService not registered, attempting registration")
            case .notFound:
                // App services can report `.notFound` before the first registration record exists
                // even when the embedded plist is present in the bundle.
                logger.debug("SMAppService daemon has no existing record yet, attempting registration")
                logToConsole("SMAppService daemon has no existing record yet, attempting registration")
            @unknown default:
                logger.warning("SMAppService unknown status")
                logToConsole("SMAppService unknown status", level: "WARN")
            }
            
            try service.register()
            logger.debug("Successfully registered daemon via SMAppService")
            logToConsole("Successfully registered daemon via SMAppService")
            verifyModernDaemonReachability(completion: completion)
        } catch {
            logger.error("Failed to register SMAppService daemon: \(String(describing: error as NSError))")
            logToConsole("Failed to register SMAppService daemon: \(String(describing: error))", level: "ERROR")
            completion(.failure(.connectionFailed))
        }
    }

    /// Fast path used when the UI knows the daemon is waiting on user approval. Re-runs
    /// `register()` to nudge the Background Task Management notification, then returns
    /// immediately so the caller can open System Settings → Login Items. Skips the long
    /// ping verification loop in `verifyModernDaemonReachability` (which would fail anyway
    /// while approval is pending).
    @available(macOS 13.0, *)
    public func surfaceApprovalPromptIfNeeded() {
        let service = SMAppService.daemon(plistName: PowerMetricsServiceConstants.modernDaemonPlistName)
        do {
            try service.register()
            logger.debug("Re-registered SMAppService daemon to surface approval prompt")
        } catch {
            logger.warning("surfaceApprovalPromptIfNeeded register() failed: \(String(describing: error as NSError))")
        }
    }

    @available(macOS 13.0, *)
    private func verifyEnabledDaemonRegistration(
        _ service: SMAppService,
        completion: @escaping (Result<Void, PowerMetricsClientError>) -> Void
    ) {
        pingDaemon { [weak self] isReachable in
            guard let self else { return }

            if isReachable {
                self.logger.debug("PowerMetricsService daemon responded to ping")
                self.logToConsole("PowerMetricsService daemon responded to ping")
                completion(.success(()))
                return
            }

            self.logger.warning("Enabled PowerMetricsService daemon is unreachable, refreshing registration")
            self.logToConsole("Enabled PowerMetricsService daemon is unreachable, refreshing registration", level: "WARN")
            self.refreshModernDaemon(service, completion: completion)
        }
    }

    @available(macOS 13.0, *)
    private func refreshModernDaemon(
        _ service: SMAppService,
        completion: @escaping (Result<Void, PowerMetricsClientError>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            do {
                try service.unregister()
            } catch {
                self.logger.warning("Failed to unregister stale daemon record: \(String(describing: error as NSError))")
                self.logToConsole("Failed to unregister stale daemon record: \(String(describing: error))", level: "WARN")
            }

            do {
                try service.register()
                self.logger.debug("Successfully refreshed daemon via SMAppService")
                self.logToConsole("Successfully refreshed daemon via SMAppService")
                self.verifyModernDaemonReachability(completion: completion)
            } catch {
                self.logger.error("Failed to refresh SMAppService daemon: \(String(describing: error as NSError))")
                self.logToConsole("Failed to refresh SMAppService daemon: \(String(describing: error))", level: "ERROR")
                completion(.failure(.connectionFailed))
            }
        }
    }

    private func verifyModernDaemonReachability(
        completion: @escaping (Result<Void, PowerMetricsClientError>) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            for delay in Self.modernHelperStartupRetryDelays {
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }

                let client = PowerMetricsServiceClient()
                defer { client.invalidate() }

                let semaphore = DispatchSemaphore(value: 0)
                var didRespond = false
                var sampleWasUsable = false

                client.ping { isReachable in
                    didRespond = isReachable
                    semaphore.signal()
                }

                guard semaphore.wait(timeout: .now() + Self.modernHelperStartupTimeout) == .success,
                      didRespond else {
                    continue
                }

                let sampleSemaphore = DispatchSemaphore(value: 0)
                client.fetchPowerMetricsSample { sampleData in
                    if let sampleData {
                        sampleWasUsable = Self.hasUsablePowerMetricsPayload(sampleData)
                    }
                    sampleSemaphore.signal()
                }
                _ = sampleSemaphore.wait(timeout: .now() + Self.modernHelperStartupTimeout)

                if sampleWasUsable {
                    self.logger.debug("PowerMetricsService daemon produced a usable sample after registration")
                } else {
                    self.logger.warning("PowerMetricsService daemon is reachable but did not produce a usable sample during registration verification")
                }
                completion(.success(()))
                return
            }

            self.logger.error("PowerMetricsService daemon did not become reachable after registration")
            completion(.failure(.connectionFailed))
        }
    }

    private static func hasUsablePowerMetricsPayload(_ data: Data) -> Bool {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data.trimmingTrailingNULBytes(),
            options: [],
            format: nil
        ) as? [String: Any] else {
            return false
        }

        let processor = root["processor"] as? [String: Any] ?? [:]
        let gpu = root["gpu"] as? [String: Any] ?? [:]
        let positiveNumericKeys = [
            processor["cpu_power"],
            processor["gpu_power"],
            processor["ane_power"],
            processor["combined_power"],
            processor["package_watts"],
            gpu["freq_hz"]
        ]

        if positiveNumericKeys.contains(where: { numericValue($0).map { $0.isFinite && $0 > 0 } ?? false }) {
            return true
        }

        if let values = processor["per_core_frequencies_hz"] as? [Double],
           values.contains(where: { $0.isFinite && $0 > 0 }) {
            return true
        }
        if let values = processor["per_core_frequencies_hz"] as? [NSNumber],
           values.contains(where: { $0.doubleValue.isFinite && $0.doubleValue > 0 }) {
            return true
        }

        return hasPositiveNestedFrequency(in: processor["clusters"])
            || hasPositiveNestedFrequency(in: processor["packages"])
    }

    private static func hasPositiveNestedFrequency(in value: Any?) -> Bool {
        if let dictionaries = value as? [[String: Any]] {
            for dictionary in dictionaries {
                if let freq = numericValue(dictionary["freq_hz"]),
                   freq.isFinite,
                   freq > 0 {
                    return true
                }
                if hasPositiveNestedFrequency(in: dictionary["cpus"])
                    || hasPositiveNestedFrequency(in: dictionary["cores"]) {
                    return true
                }
            }
        }
        return false
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    @available(macOS 13.0, *)
    private func pingDaemon(timeout: TimeInterval = 1.5, completion: @escaping (Bool) -> Void) {
        let connection = NSXPCConnection(
            machServiceName: PowerMetricsServiceConstants.modernMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PowerMetricsXPCProtocol.self)

        let stateQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.PowerMetricsServiceRegistrar.ping")
        var finished = false

        func finish(_ result: Bool) {
            stateQueue.sync {
                guard !finished else { return }
                finished = true
                connection.invalidationHandler = nil
                connection.interruptionHandler = nil
                connection.invalidate()
                completion(result)
            }
        }

        connection.invalidationHandler = {
            finish(false)
        }
        connection.interruptionHandler = {
            finish(false)
        }

        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            finish(false)
        }) as? PowerMetricsXPCProtocol else {
            finish(false)
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            finish(false)
        }

        proxy.ping { response in
            finish(response == "pong")
        }
    }
    
    // MARK: - Legacy Registration (macOS 11-12)
    
    private func registerWithSMJobBless(
        forceReplaceExisting: Bool,
        completion: @escaping (Result<Void, PowerMetricsClientError>) -> Void
    ) {
        var authRef: AuthorizationRef?
        let authFlags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        
        logToConsole("Starting SMJobBless registration...")
        
        // Create authorization reference
        let authStatus: OSStatus = kSMRightBlessPrivilegedHelper.withCString { blessRightName in
            var authItem = AuthorizationItem(
                name: blessRightName,
                valueLength: 0,
                value: nil,
                flags: 0
            )

            return withUnsafeMutablePointer(to: &authItem) { authItemPointer in
                var authRights = AuthorizationRights(count: 1, items: authItemPointer)
                return AuthorizationCreate(&authRights, nil, authFlags, &authRef)
            }
        }
        
        guard authStatus == errAuthorizationSuccess, let authRef = authRef else {
            logger.error("Failed to create authorization reference: \(authStatus)")
            logToConsole("Failed to create authorization reference: \(authStatus)", level: "ERROR")
            completion(.failure(.connectionFailed))
            return
        }
        
        defer { AuthorizationFree(authRef, []) }

        if forceReplaceExisting {
            removeLegacyHelperIfPresent(using: authRef)
        }
        
        logToConsole("Authorization created, blessing helper tool...")
        
        // Attempt to bless the helper tool
        var cfError: Unmanaged<CFError>?
        let success = SMJobBless(
            kSMDomainSystemLaunchd,
            PowerMetricsServiceConstants.legacyHelperBundleID as CFString,
            authRef,
            &cfError
        )
        
        if success {
            logger.debug("Successfully registered daemon via SMJobBless")
            logToConsole("Successfully registered daemon via SMJobBless")

            guard ensureLegacyHelperReady() else {
                logger.error("Legacy power metrics helper was blessed but never became reachable")
                logToConsole("Legacy power metrics helper was blessed but never became reachable", level: "ERROR")
                completion(.failure(.connectionFailed))
                return
            }

            completion(.success(()))
        } else {
            let error = cfError?.takeRetainedValue()
            let errorDescription = error.map { String(describing: $0) } ?? "Unknown error"
            logger.error("Failed to bless helper tool: \(errorDescription)")
            logToConsole("Failed to bless helper tool: \(errorDescription)", level: "ERROR")
            completion(.failure(.connectionFailed))
        }
    }

    private func removeLegacyHelperIfPresent(using authRef: AuthorizationRef) {
        guard PowerMetricsServiceAvailability.isLegacyPrivilegedHelperInstalled else {
            return
        }

        logger.debug("Attempting to remove the installed legacy power metrics helper before re-blessing")
        logToConsole("Attempting to remove the installed legacy power metrics helper before re-blessing")

        var cfError: Unmanaged<CFError>?
        let removed = SMJobRemove(
            kSMDomainSystemLaunchd,
            PowerMetricsServiceConstants.legacyHelperBundleID as CFString,
            authRef,
            true,
            &cfError
        )

        if removed {
            logger.debug("Removed installed legacy power metrics helper before re-blessing")
            logToConsole("Removed installed legacy power metrics helper before re-blessing")
            return
        }

        let error = cfError?.takeRetainedValue()
        logger.warning("Failed to remove installed legacy power metrics helper before re-blessing: \(String(describing: error))")
        logToConsole(
            "Failed to remove installed legacy power metrics helper before re-blessing: \(String(describing: error))",
            level: "WARN"
        )
    }

    private func ensureLegacyHelperReady() -> Bool {
        for delay in Self.legacyHelperStartupRetryDelays {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }

            let client = PowerMetricsServiceClient()
            defer { client.invalidate() }

            let semaphore = DispatchSemaphore(value: 0)
            var didRespond = false

            client.ping { isReachable in
                didRespond = isReachable
                semaphore.signal()
            }

            let waitResult = semaphore.wait(timeout: .now() + Self.legacyHelperStartupTimeout)
            guard waitResult == .success, didRespond else {
                continue
            }

            return true
        }

        return false
    }
}

private extension Data {
    func trimmingTrailingNULBytes() -> Data {
        var endIndex = count
        while endIndex > 0, self[endIndex - 1] == 0 {
            endIndex -= 1
        }
        guard endIndex < count else { return self }
        return Data(prefix(endIndex))
    }
}
