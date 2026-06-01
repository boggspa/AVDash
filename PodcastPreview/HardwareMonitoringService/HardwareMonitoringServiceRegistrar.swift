import Foundation
import PodcastPreviewCore
import ServiceManagement
import Security
import os.log
#if canImport(libproc)
import libproc
#endif

final class HardwareMonitoringServiceRegistrar {
    @available(macOS 13.0, *)
    private static let refreshRecoveryRetryDelays: [TimeInterval] = [0.0, 0.25, 0.75, 1.5]
    private static let legacyHelperStartupRetryDelays: [TimeInterval] = [0.0, 0.25, 0.75, 1.5, 3.0]
    private static let legacyHelperStartupTimeout: TimeInterval = 2.0

    private let logger = Logger(
        subsystem: HardwareMonitoringServiceConstants.mainAppBundleID,
        category: "HardwareMonitoringServiceRegistrar"
    )
    private let legacyDescriptor = LegacyUserLaunchAgentDescriptor(
        plistName: HardwareMonitoringServiceConstants.legacyLaunchAgentPlistName,
        label: HardwareMonitoringServiceConstants.legacyLaunchAgentLabel,
        helperExecutableName: HardwareMonitoringServiceConstants.legacyLaunchAgentHelperExecutableName
    )

    @available(macOS 13.0, *)
    private func makeService() -> SMAppService {
        SMAppService.daemon(plistName: HardwareMonitoringServiceConstants.modernDaemonPlistName)
    }

    @available(macOS 13.0, *)
    private func refreshRegistration(_ service: SMAppService) throws {
        do {
            try service.unregister()
            logger.debug("Hardware monitoring daemon unregistered for refresh")
        } catch {
            logger.warning("Hardware monitoring daemon unregister during refresh failed: \(String(describing: error as NSError))")
        }

        var lastError: Error?

        for delay in Self.refreshRecoveryRetryDelays {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }

            do {
                try makeService().register()
                logger.debug("Hardware monitoring daemon registration refreshed")

                if pingDaemonSynchronously() {
                    logger.debug("Hardware monitoring daemon became reachable again during refresh recovery")
                    return
                }

                logger.warning("Hardware monitoring daemon refreshed but is still unreachable during refresh recovery")
                lastError = HardwareMonitoringClientError.registrationFailed
            } catch {
                lastError = error
                logger.warning("Hardware monitoring daemon refresh attempt failed: \(String(describing: error as NSError))")
            }
        }

        throw lastError ?? HardwareMonitoringClientError.registrationFailed
    }

    func registerIfNeeded(
        forceRefresh: Bool = false,
        completion: @escaping (Result<Void, HardwareMonitoringClientError>) -> Void
    ) {
        guard HardwareMonitoringServiceAvailability.isSupportedOS else {
            completion(.failure(.unavailable))
            return
        }

        if HardwareMonitoringServiceAvailability.usesLegacyPrivilegedHelper {
            DispatchQueue.global(qos: .utility).async {
                if !forceRefresh, self.ensureHeadlessServiceReady() {
                    self.logger.debug("Hardware monitoring privileged helper already reachable")
                    completion(.success(()))
                    return
                }

                do {
                    try self.registerWithSMJobBless()
                    guard self.ensureHeadlessServiceReady() else {
                        self.logger.error("Hardware monitoring privileged helper was blessed but never became reachable")
                        completion(.failure(.registrationFailed))
                        return
                    }

                    self.logger.debug("Hardware monitoring privileged helper installed via SMJobBless")
                    completion(.success(()))
                } catch {
                    self.logger.error("Failed to install legacy hardware monitoring privileged helper: \(String(describing: error as NSError))")
                    completion(.failure(.registrationFailed))
                }
            }
            return
        }

        if HardwareMonitoringServiceAvailability.usesLegacyUserLaunchAgent {
            DispatchQueue.global(qos: .utility).async {
                let wasReachable = self.ensureHeadlessServiceReady()
                if wasReachable {
                    self.logger.debug("Refreshing reachable legacy hardware monitoring LaunchAgent to pick up the latest bundled helper")
                }

                do {
                    try LegacyUserLaunchAgentSupport.registerOrRefresh(self.legacyDescriptor)
                    guard self.ensureHeadlessServiceReady() else {
                        self.logger.error("Hardware monitoring legacy LaunchAgent was registered but never became reachable")
                        completion(.failure(.registrationFailed))
                        return
                    }

                    self.logger.debug("Hardware monitoring legacy LaunchAgent registered")
                    completion(.success(()))
                } catch {
                    self.logger.error("Failed to register legacy hardware monitoring LaunchAgent: \(String(describing: error as NSError))")
                    completion(.failure(.registrationFailed))
                }
            }
            return
        }

        guard #available(macOS 13.0, *) else {
            completion(.failure(.unavailable))
            return
        }

        registerWithSMAppService(forceRefresh: forceRefresh, completion: completion)
    }

    func unregister(completion: @escaping (Result<Void, HardwareMonitoringClientError>) -> Void) {
        guard HardwareMonitoringServiceAvailability.isSupportedOS else {
            completion(.failure(.unavailable))
            return
        }

        if HardwareMonitoringServiceAvailability.usesLegacyPrivilegedHelper {
            DispatchQueue.global(qos: .utility).async {
                do {
                    try self.unregisterWithSMJobBless()
                    self.logger.debug("Hardware monitoring privileged helper removed via SMJobRemove")
                    completion(.success(()))
                } catch {
                    self.logger.error("Failed to remove legacy hardware monitoring privileged helper: \(String(describing: error as NSError))")
                    completion(.failure(.registrationFailed))
                }
            }
            return
        }

        if HardwareMonitoringServiceAvailability.usesLegacyUserLaunchAgent {
            DispatchQueue.global(qos: .utility).async {
                do {
                    _ = try LegacyUserLaunchAgentSupport.unregisterIfPresent(self.legacyDescriptor)
                    self.logger.debug("Hardware monitoring legacy LaunchAgent removed")
                    completion(.success(()))
                } catch {
                    self.logger.error("Failed to remove legacy hardware monitoring LaunchAgent: \(String(describing: error as NSError))")
                    completion(.failure(.registrationFailed))
                }
            }
            return
        }

        guard #available(macOS 13.0, *) else {
            completion(.failure(.unavailable))
            return
        }

        do {
            try makeService().unregister()
            logger.debug("Hardware monitoring daemon unregistered")
            completion(.success(()))
        } catch {
            logger.error("Failed to unregister hardware monitoring daemon: \(String(describing: error as NSError))")
            completion(.failure(.registrationFailed))
        }
    }

    private func registerWithSMJobBless() throws {
        do {
            if try LegacyUserLaunchAgentSupport.unregisterIfPresent(legacyDescriptor) {
                logger.debug("Removed legacy user hardware monitoring LaunchAgent before blessing the privileged helper")
            }
        } catch {
            logger.warning("Failed to remove legacy user hardware monitoring LaunchAgent before blessing: \(String(describing: error as NSError))")
        }

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
            throw HardwareMonitoringClientError.registrationFailed
        }

        defer { AuthorizationFree(authRef, []) }

        var cfError: Unmanaged<CFError>?
        let success = SMJobBless(
            kSMDomainSystemLaunchd,
            HardwareMonitoringServiceConstants.legacyHelperBundleID as CFString,
            authRef,
            &cfError
        )

        guard success else {
            let error = cfError?.takeRetainedValue()
            logger.error("Failed to bless hardware monitoring helper: \(String(describing: error))")
            throw HardwareMonitoringClientError.registrationFailed
        }
    }

    private func unregisterWithSMJobBless() throws {
        guard HardwareMonitoringServiceAvailability.isLegacyPrivilegedHelperInstalled else {
            return
        }

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
            throw HardwareMonitoringClientError.registrationFailed
        }

        defer { AuthorizationFree(authRef, []) }

        var cfError: Unmanaged<CFError>?
        let removed = SMJobRemove(
            kSMDomainSystemLaunchd,
            HardwareMonitoringServiceConstants.legacyHelperBundleID as CFString,
            authRef,
            true,
            &cfError
        )

        guard removed else {
            let error = cfError?.takeRetainedValue()
            logger.error("Failed to remove hardware monitoring helper: \(String(describing: error))")
            throw HardwareMonitoringClientError.registrationFailed
        }
    }

    private func ensureHeadlessServiceReady() -> Bool {
        for delay in Self.legacyHelperStartupRetryDelays {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }

            let client = HardwareMonitoringServiceClient()
            defer { client.invalidate() }

            let semaphore = DispatchSemaphore(value: 0)
            var snapshot: HardwareCollectorStatusSnapshot?

            client.fetchStatus { response in
                snapshot = response
                semaphore.signal()
            }

            let waitResult = semaphore.wait(timeout: .now() + Self.legacyHelperStartupTimeout)
            guard waitResult == .success, let snapshot else {
                continue
            }

            if snapshot.isCollectorInitialized, snapshot.isMonitoringActive {
                return true
            }

            let startSemaphore = DispatchSemaphore(value: 0)
            var startedSnapshot: HardwareCollectorStatusSnapshot?

            client.setCollectionProfile(.historyOnly) { response in
                startedSnapshot = response
                startSemaphore.signal()
            }

            let startResult = startSemaphore.wait(timeout: .now() + Self.legacyHelperStartupTimeout)
            guard startResult == .success,
                  let startedSnapshot,
                  startedSnapshot.isCollectorInitialized,
                  startedSnapshot.isMonitoringActive else {
                continue
            }

            return true
        }

        return false
    }

    @available(macOS 13.0, *)
    private func registerWithSMAppService(
        forceRefresh: Bool,
        completion: @escaping (Result<Void, HardwareMonitoringClientError>) -> Void
    ) {
        let service = SMAppService.daemon(plistName: HardwareMonitoringServiceConstants.modernDaemonPlistName)

        do {
            if try LegacyUserLaunchAgentSupport.unregisterIfPresent(legacyDescriptor) {
                logger.debug("Removed legacy hardware monitoring LaunchAgent while registering the system daemon")
            }
        } catch {
            logger.warning("Failed to remove legacy hardware monitoring LaunchAgent: \(String(describing: error as NSError))")
        }

        if HardwareMonitoringServiceAvailability.isModernDaemonInstalled {
            if forceRefresh {
                logger.debug("Hardware monitoring daemon refresh was explicitly requested")
                do {
                    try refreshRegistration(service)
                    completion(.success(()))
                } catch {
                    logger.error("Failed to refresh hardware monitoring daemon: \(String(describing: error as NSError))")
                    completion(.failure(.registrationFailed))
                }
                return
            }

            if pingDaemonSynchronously() {
                if runningDaemonPredatesBundledBinary() {
                    logger.debug("Hardware monitoring daemon predates the bundled helper binary, refreshing registration")
                    do {
                        try refreshRegistration(service)
                        completion(.success(()))
                    } catch {
                        logger.error("Failed to refresh outdated hardware monitoring daemon: \(String(describing: error as NSError))")
                        completion(.failure(.registrationFailed))
                    }
                    return
                }

                logger.debug("Hardware monitoring daemon already reachable")
                completion(.success(()))
                return
            }

            logger.warning("Installed hardware monitoring daemon is not responding, refreshing registration")
            do {
                try refreshRegistration(service)
                completion(.success(()))
            } catch {
                logger.error("Failed to refresh hardware monitoring daemon: \(String(describing: error as NSError))")
                completion(.failure(.registrationFailed))
            }
            return
        }

        do {
            try service.register()
            logger.debug("Hardware monitoring daemon registration succeeded, verifying reachability")
            verifyEnabledDaemonRegistration(service, completion: completion)
        } catch {
            logger.error("Failed to register hardware monitoring daemon: \(String(describing: error as NSError))")
            completion(.failure(.registrationFailed))
        }
    }

    @available(macOS 13.0, *)
    private func verifyEnabledDaemonRegistration(
        _ service: SMAppService,
        completion: @escaping (Result<Void, HardwareMonitoringClientError>) -> Void
    ) {
        pingDaemon { [weak self] isReachable in
            guard let self else { return }

            if isReachable {
                if self.runningDaemonPredatesBundledBinary() {
                    self.logger.debug("Hardware monitoring daemon predates the bundled helper binary, refreshing registration")
                    do {
                        try self.refreshRegistration(service)
                        completion(.success(()))
                    } catch {
                        self.logger.error("Failed to refresh outdated hardware monitoring daemon: \(String(describing: error as NSError))")
                        completion(.failure(.registrationFailed))
                    }
                    return
                }

                self.logger.debug("Hardware monitoring daemon responded to status ping")
                completion(.success(()))
                return
            }

            self.logger.warning("Enabled hardware monitoring daemon is unreachable, refreshing registration")

            do {
                try self.refreshRegistration(service)
                completion(.success(()))
            } catch {
                self.logger.error("Failed to refresh hardware monitoring daemon: \(String(describing: error as NSError))")
                completion(.failure(.registrationFailed))
            }
        }
    }

    @available(macOS 13.0, *)
    private func pingDaemon(timeout: TimeInterval = 1.5, completion: @escaping (Bool) -> Void) {
        let connection = NSXPCConnection(
            machServiceName: HardwareMonitoringServiceConstants.modernMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: HardwareMonitoringXPCProtocol.self)

        let stateQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.HardwareMonitoringServiceRegistrar.ping")
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
        }) as? HardwareMonitoringXPCProtocol else {
            finish(false)
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            finish(false)
        }

        proxy.fetchStatus { data in
            finish(data != nil)
        }
    }

    @available(macOS 13.0, *)
    private func pingDaemonSynchronously(timeout: TimeInterval = 1.0) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isReachable = false

        pingDaemon(timeout: timeout) { reachable in
            isReachable = reachable
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + timeout + 0.25)
        return isReachable
    }

    @available(macOS 13.0, *)
    private func runningDaemonPredatesBundledBinary() -> Bool {
        guard let helperBinaryURL = helperBinaryURL(),
              let bundledModificationDate = fileModificationDate(at: helperBinaryURL),
              let daemonSnapshot = runningModernDaemonSnapshot() else {
            return false
        }

        guard let daemonStartDate = daemonSnapshot.startDate else {
            logger.debug("Hardware monitoring daemon start date was unavailable; refreshing defensively")
            return true
        }

        return daemonStartDate.addingTimeInterval(1.0) < bundledModificationDate
    }

    @available(macOS 13.0, *)
    private func helperBinaryURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        let helperURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchServices")
            .appendingPathComponent(HardwareMonitoringServiceConstants.modernHelperExecutableName)

        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            return nil
        }
        return helperURL
    }

    @available(macOS 13.0, *)
    private func fileModificationDate(at url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    @available(macOS 13.0, *)
    private func runningModernDaemonSnapshot() -> ProcessSnapshot? {
        let expectedName = HardwareMonitoringServiceConstants.modernHelperExecutableName
        let expectedPathSuffix = "/Contents/Library/LaunchServices/\(expectedName)"
        let expectedRelativePathSuffix = String(expectedPathSuffix.dropFirst())

        return listAllPIDs()
            .compactMap(readProcessSnapshot(pid:))
            .filter { snapshot in
                snapshot.userID == 0
                    && snapshot.executableName == expectedName
                    && (
                        snapshot.path.hasSuffix(expectedPathSuffix)
                        || snapshot.path.hasSuffix(expectedRelativePathSuffix)
                    )
            }
            .max(by: { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) })
    }

    @available(macOS 13.0, *)
    private func listAllPIDs() -> [Int32] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        if bytesNeeded <= 0 { return [] }

        let count = bytesNeeded / Int32(MemoryLayout<pid_t>.stride)
        var buffer = Array<pid_t>(repeating: 0, count: Int(count))

        let bytesFilled = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, bytesNeeded)
        }
        if bytesFilled <= 0 { return [] }

        let filledCount = Int(bytesFilled) / MemoryLayout<pid_t>.stride
        return buffer.prefix(filledCount).map { Int32($0) }
    }

    @available(macOS 13.0, *)
    private func readProcessSnapshot(pid: Int32) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }

        var bsdInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let infoResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, infoSize)

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }

        let path = String(cString: pathBuffer)
        let executableName = URL(fileURLWithPath: path).lastPathComponent
        guard !executableName.isEmpty else { return nil }

        let metadata: (startDate: Date?, userID: uid_t?)
        if infoResult == infoSize {
            let seconds = TimeInterval(bsdInfo.pbi_start_tvsec)
            let microseconds = TimeInterval(bsdInfo.pbi_start_tvusec) / 1_000_000.0
            metadata = (
                startDate: Date(timeIntervalSince1970: seconds + microseconds),
                userID: bsdInfo.pbi_uid
            )
        } else {
            metadata = readProcessMetadataUsingSysctl(pid: pid)
        }

        return ProcessSnapshot(
            pid: pid,
            executableName: executableName,
            path: path,
            userID: metadata.userID,
            startDate: metadata.startDate
        )
    }

    @available(macOS 13.0, *)
    private func readProcessMetadataUsingSysctl(pid: Int32) -> (startDate: Date?, userID: uid_t?) {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var processInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &processInfo, &size, nil, 0)

        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else {
            return (nil, nil)
        }

        let seconds = TimeInterval(processInfo.kp_proc.p_starttime.tv_sec)
        let microseconds = TimeInterval(processInfo.kp_proc.p_starttime.tv_usec) / 1_000_000.0
        let startDate = seconds > 0 ? Date(timeIntervalSince1970: seconds + microseconds) : nil
        return (startDate, processInfo.kp_eproc.e_ucred.cr_uid)
    }
}

private extension HardwareMonitoringServiceRegistrar {
    struct ProcessSnapshot {
        let pid: Int32
        let executableName: String
        let path: String
        let userID: uid_t?
        let startDate: Date?
    }
}
