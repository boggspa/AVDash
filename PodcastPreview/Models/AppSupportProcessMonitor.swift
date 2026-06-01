import Foundation
import Combine
import ServiceManagement
import CoreAudio
import PodcastPreviewCore
#if canImport(libproc)
import libproc
#else
// libproc symbols are available via Darwin on many SDKs; keep explicit import only if it compiles.
#endif

final class AppSupportProcessMonitor: ObservableObject {
    enum Status: String {
        case unknown
        case idle
        case active

        var displayText: String {
            rawValue.capitalized
        }
    }

    struct RowAction: Equatable {
        let id: String
        let title: String
        let inProgressTitle: String
        let isEnabled: Bool
        let isInProgress: Bool
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let status: Status
        let uptimeText: String
        let statusLabel: String?
        let detailText: String?
        let action: RowAction?
        let uninstallAction: RowAction?
    }

    private enum RegistrationState {
        case known
        case unknown
    }

    /// Distinguishes the three "Unknown" sub-states that SMAppService can report on macOS 13+.
    /// SMJobBless builds collapse to either `.enabled` or `.notRegistered`. Older OS or platform
    /// paths report `.unsupported`.
    private enum PowerMetricsApprovalState: Equatable {
        case unsupported
        case enabled
        case requiresApproval
        case notRegistered
    }

    private enum ServiceKind {
        case hardwareAgent
        case audioAgent
        case audioDriver
        case virtualCameraDriver
        case powerMetrics
    }

    private enum ServiceOperation {
        case installOrRepair
        case uninstall

        var titleSuffix: String {
            switch self {
            case .installOrRepair:
                return "install/repair"
            case .uninstall:
                return "uninstall"
            }
        }

        func progressTitle(for baseTitle: String) -> String {
            switch self {
            case .installOrRepair:
                if baseTitle.localizedCaseInsensitiveContains("install") {
                    return "Installing..."
                }
                return "Repairing..."
            case .uninstall:
                return "Uninstalling..."
            }
        }
    }

    private struct PowerMetricsHealth: Equatable {
        enum SampleState: Equatable {
            case unavailable
            case respondedWithoutUsableSample
            case usableSample
        }

        var sampleState: SampleState
        var helperSnapshot: PowerMetricsHealthSnapshot?

        static let unavailable = PowerMetricsHealth(sampleState: .unavailable)
        static let respondedWithoutUsableSample = PowerMetricsHealth(sampleState: .respondedWithoutUsableSample)
        static let usableSample = PowerMetricsHealth(sampleState: .usableSample)

        var isXPCReachable: Bool {
            helperSnapshot != nil || sampleState != .unavailable
        }
    }

    private struct ServiceDescriptor {
        let id: String
        let name: String
        let executableNames: [String]
        let kind: ServiceKind
    }

    private struct ProcessSnapshot {
        let pid: Int32
        let executableName: String
        let startDate: Date?
        let userID: uid_t?

        var isRootOwned: Bool {
            userID == 0
        }

        var isUserOwned: Bool {
            guard let userID else { return false }
            return userID != 0
        }

        var uptimeText: String {
            Self.formatUptime(since: startDate)
        }

        private static func formatUptime(since startDate: Date?) -> String {
            guard let startDate else { return "—" }
            let dt = max(0, Date().timeIntervalSince(startDate))
            let seconds = Int(dt)
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            if hours > 0 {
                return String(format: "%dh %dm", hours, minutes)
            }
            return String(format: "%dm", minutes)
        }
    }

    private struct SampleContext {
        let runningProcesses: [ProcessSnapshot]
        let hardwareAgentReachable: Bool
        let audioStatus: AudioRoutingStatusSnapshot?
        let powerMetricsHealth: PowerMetricsHealth
        let audioDriverPresent: Bool
        let virtualCameraDriverPresent: Bool
        let hardwareHistoryMigration: HardwareHistoryMigrationAssessment?
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var hardwareHistoryMigrationAssessment: HardwareHistoryMigrationAssessment?

    private var timer: DispatchSourceTimer?
    private let samplingInterval: TimeInterval = 30
    private let samplingQueue = DispatchQueue(
        label: "com.chrisizatt.PodcastPreview.AppSupportProcessMonitor",
        qos: .utility
    )
    private let hardwareClient = HardwareMonitoringServiceClient()
    private let audioClient = AudioRoutingServiceClient()
    private let powerClient = PowerMetricsServiceClient()
    private var latestHardwareDataEvidenceDate: Date?
    private var hardwareAgentAutoRepairAttemptedForCurrentStall = false
    private var powerMetricsDegradedStartDate: Date?
    private var powerMetricsAutoRepairAttemptedForCurrentStall = false
    private var lastPowerMetricsApprovalState: PowerMetricsApprovalState?
    private var powerMetricsLastRegistrationAttemptDate: Date?
    private let powerMetricsRegistrationRetryInterval: TimeInterval = 300
    private var actionMessagesByID: [String: String] = [:]
    private var actionInFlightIDs: Set<String> = []

    private var hardwareDataFreshnessWindow: TimeInterval {
        max(5, Double(HardwareCollectionSettings.collectorIntervalSeconds()) * 4)
    }

    private var hardwareAgentAutoRepairStallThreshold: TimeInterval {
        max(120, Double(HardwareCollectionSettings.collectorIntervalSeconds()) * 120)
    }

    private var powerMetricsAutoRepairStallThreshold: TimeInterval {
        max(120, Double(HardwareCollectionSettings.collectorIntervalSeconds()) * 120)
    }

    private var usesLegacyAudioAgentRegistration: Bool {
        LegacyUserLaunchAgentSupport.isSupportedOnCurrentOS
    }

    private var hardwareAgentUsesSeparateService: Bool {
        HardwareMonitoringFeatureFlags.prefersHeadlessAgentBackend && hardwareClient.isSupportedPlatform
    }

    private var hardwareAgentUsesSystemDaemonRegistration: Bool {
        hardwareAgentUsesSeparateService && HardwareMonitoringServiceAvailability.usesSMAppServiceDaemon
    }

    private var hardwareAgentUsesLegacyPrivilegedHelperRegistration: Bool {
        hardwareAgentUsesSeparateService && HardwareMonitoringServiceAvailability.usesLegacyPrivilegedHelper
    }

    private var hardwareAgentUsesPrivilegedRegistration: Bool {
        hardwareAgentUsesSystemDaemonRegistration || hardwareAgentUsesLegacyPrivilegedHelperRegistration
    }

    private var hardwareAgentServiceDisplayName: String {
        if hardwareAgentUsesSystemDaemonRegistration {
            return "system daemon"
        }
        if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
            return "privileged helper"
        }
        return "launch agent"
    }

    private var hardwareAgentApprovalLocation: String {
        if hardwareAgentUsesSystemDaemonRegistration {
            return "System Settings"
        }
        if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
            return "an administrator approval prompt"
        }
        return "Login Items"
    }

    private var hardwareAgentRowName: String {
        if !hardwareAgentUsesSeparateService {
            return "Hardware Agent (Built-In)"
        }
        if hardwareAgentUsesSystemDaemonRegistration {
            return "Hardware Agent (System)"
        }
        if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
            return "Hardware Agent (Privileged)"
        }
        return "Hardware Agent (User)"
    }

    private static func relativeAgeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        return "\(hours)h \(remainderMinutes)m ago"
    }

    var helperServicesFocusSubtitle: String {
        var parts = ["Health checks run in the app."]
        if hardwareAgentUsesSystemDaemonRegistration {
            parts.append("On macOS 13+, the hardware service is a system daemon reached over privileged XPC.")
        } else if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
            parts.append("On macOS 11-12, the hardware service is a privileged helper installed with administrator approval via SMJobBless.")
        } else if hardwareAgentUsesSeparateService {
            parts.append("On this OS, the hardware service is a per-user helper rather than a privileged system service.")
        } else {
            parts.append("On this build, hardware monitoring is still running inside the app process.")
        }
        if hardwareAgentUsesPrivilegedRegistration {
            parts.append("If the stream stays stale long enough, the app will try to refresh the helper automatically before you need to repair it manually.")
        }
        parts.append("The FireWireNetBridge driver installs into /Library/Audio/Plug-Ins/HAL and enables network audio bridging between Macs.")
        parts.append("The PodcastPreview virtual camera installs into /Library/CoreMediaIO/Plug-Ins/DAL when a bundled payload is present.")
        return parts.joined(separator: " ")
    }

    var helperServicesFocusDetailLines: [String] {
        var lines = [
            "Install and Repair refresh bundled registrations in place; Uninstall unregisters helpers or removes installed driver bundles and then verifies the result."
        ]

        if hardwareAgentUsesSystemDaemonRegistration {
            lines.append("On macOS 13+, Hardware Agent is the system daemon path; the UI acts as a client and does not replace daemon-owned hardware history with its own user-space writes.")
        } else if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
            lines.append("On macOS 11-12, Hardware Agent uses a privileged SMJobBless helper so retained hardware history can keep collecting even when the app UI is closed.")
        } else if hardwareAgentUsesSeparateService {
            lines.append("On this OS, Hardware Agent still runs as a per-user helper rather than a privileged system service.")
        } else {
            lines.append("On this build, hardware history stays in the app process and remains user-space only.")
        }

        if let migrationAssessment = hardwareHistoryMigrationAssessment,
           hardwareAgentUsesPrivilegedRegistration {
            lines.append(contentsOf: helperServicesMigrationDetailLines(from: migrationAssessment))
        }

        lines.append("Virtual Camera Driver install copies the bundled DAL payload into /Library/CoreMediaIO/Plug-Ins/DAL and refreshes camera assistant services so camera clients can rediscover it.")

        lines.append("Unknown can mean missing registration, user approval still pending, or an unsupported OS/service path.")
        lines.append("The FireWireNetBridge driver enables transmitting and receiving audio over the network. Install copies the bundled HAL driver and restarts coreaudiod so the system can discover the FireWireNetBridge device.")
        return lines
    }

    func start() {
        stop()
        hardwareAgentAutoRepairAttemptedForCurrentStall = false
        samplingQueue.async { [weak self] in
            self?.sample()
        }

        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(deadline: .now() + samplingInterval, repeating: samplingInterval)
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        hardwareClient.invalidate()
        audioClient.invalidate()
        hardwareAgentAutoRepairAttemptedForCurrentStall = false
    }

    func updateHardwareDataEvidenceDate(_ date: Date?) {
        samplingQueue.async { [weak self] in
            guard let self else { return }
            let wasFresh = self.isHardwareDataEvidenceFresh(now: Date())
            self.latestHardwareDataEvidenceDate = date
            let isFresh = self.isHardwareDataEvidenceFresh(now: Date())
            if isFresh {
                self.hardwareAgentAutoRepairAttemptedForCurrentStall = false
            }
            guard wasFresh != isFresh, self.timer != nil else { return }
            self.sample()
        }
    }

    private func sample() {
        let now = Date()
        let hardwareEvidenceFresh = isHardwareDataEvidenceFresh(now: now)
        let migrationAssessment = hardwareHistoryMigrationAssessmentForCurrentMode()
        let hardwareAgentRegistrationState = registrationState(for: .hardwareAgent)
        let powerApprovalState = powerMetricsApprovalState()
        let previousPowerApprovalState = lastPowerMetricsApprovalState
        lastPowerMetricsApprovalState = powerApprovalState
        let powerRegistrationState: RegistrationState = powerApprovalState == .enabled ? .known : .unknown
        let context = SampleContext(
            runningProcesses: Self.runningProcessSnapshots(),
            hardwareAgentReachable: hardwareEvidenceFresh || (
                hardwareAgentRegistrationState == .known
                    ? waitForHardwareAgentStatus()
                    : false
            ),
            audioStatus: registrationState(for: .audioAgent) == .known
                ? fetchAudioAgentStatus()
                : nil,
            powerMetricsHealth: powerRegistrationState == .known
                ? fetchPowerMetricsHealth()
                : .unavailable,
            audioDriverPresent: Self.isAudioDriverInstalled(),
            virtualCameraDriverPresent: Self.isVirtualCameraDriverInstalled(),
            hardwareHistoryMigration: migrationAssessment
        )

        let rows = descriptors().map { descriptor in
            makeRow(for: descriptor, context: context)
        }

        DispatchQueue.main.async {
            self.rows = rows
            self.hardwareHistoryMigrationAssessment = migrationAssessment
        }

        if shouldAutomaticallyRepairHardwareAgent(
            now: now,
            hardwareEvidenceFresh: hardwareEvidenceFresh,
            hardwareAgentRegistrationState: hardwareAgentRegistrationState
        ) {
            beginAutomaticHardwareAgentRepair()
        }

        updatePowerMetricsAutoRepairState(
            now: now,
            registrationState: powerRegistrationState,
            health: context.powerMetricsHealth
        )

        handlePowerMetricsApprovalStateChange(
            now: now,
            previous: previousPowerApprovalState,
            current: powerApprovalState
        )
    }

    private func isHardwareDataEvidenceFresh(now: Date) -> Bool {
        guard let latestHardwareDataEvidenceDate else { return false }
        return now.timeIntervalSince(latestHardwareDataEvidenceDate) <= hardwareDataFreshnessWindow
    }

    private func shouldAutomaticallyRepairHardwareAgent(
        now: Date,
        hardwareEvidenceFresh: Bool,
        hardwareAgentRegistrationState: RegistrationState
    ) -> Bool {
        guard hardwareAgentUsesSeparateService,
              hardwareAgentUsesPrivilegedRegistration,
              hardwareAgentRegistrationState == .known,
              !hardwareEvidenceFresh,
              let latestHardwareDataEvidenceDate else {
            return false
        }

        guard now.timeIntervalSince(latestHardwareDataEvidenceDate) >= hardwareAgentAutoRepairStallThreshold else {
            return false
        }

        guard !hardwareAgentAutoRepairAttemptedForCurrentStall,
              !isServiceActionInFlight(serviceIdentifier(for: .hardwareAgent)),
              isHelperInstallAvailable(for: .hardwareAgent) else {
            return false
        }

        return true
    }

    private func beginAutomaticHardwareAgentRepair() {
        let rowID = serviceIdentifier(for: .hardwareAgent)
        let actionID = primaryActionID(for: rowID)
        guard !isServiceActionInFlight(rowID) else { return }

        hardwareAgentAutoRepairAttemptedForCurrentStall = true
        actionInFlightIDs.insert(actionID)
        actionMessagesByID[rowID] = "Auto-repairing a stale hardware stream."
        sample()

        let registrar = HardwareMonitoringServiceRegistrar()
        registrar.registerIfNeeded(forceRefresh: true) { [weak self] result in
            self?.finishAction(
                for: actionID,
                result: result.mapError { $0 as Error },
                successMessage: "Hardware agent was automatically refreshed after a stale collection window.",
                operation: .installOrRepair,
                serviceKind: .hardwareAgent
            )
        }
    }

    private func updatePowerMetricsAutoRepairState(
        now: Date,
        registrationState: RegistrationState,
        health: PowerMetricsHealth
    ) {
        guard registrationState == .known,
              PowerMetricsServiceAvailability.isSupportedOS else {
            powerMetricsDegradedStartDate = nil
            powerMetricsAutoRepairAttemptedForCurrentStall = false
            return
        }

        if health.sampleState == .usableSample {
            powerMetricsDegradedStartDate = nil
            powerMetricsAutoRepairAttemptedForCurrentStall = false
            return
        }

        if powerMetricsDegradedStartDate == nil {
            powerMetricsDegradedStartDate = now
            return
        }

        guard let powerMetricsDegradedStartDate,
              now.timeIntervalSince(powerMetricsDegradedStartDate) >= powerMetricsAutoRepairStallThreshold,
              !powerMetricsAutoRepairAttemptedForCurrentStall,
              !isServiceActionInFlight(serviceIdentifier(for: .powerMetrics)),
              isHelperInstallAvailable(for: .powerMetrics) else {
            return
        }

        beginAutomaticPowerMetricsRepair()
    }

    private func beginAutomaticPowerMetricsRepair() {
        let rowID = serviceIdentifier(for: .powerMetrics)
        let actionID = primaryActionID(for: rowID)
        guard !isServiceActionInFlight(rowID) else { return }

        powerMetricsAutoRepairAttemptedForCurrentStall = true
        actionInFlightIDs.insert(actionID)
        actionMessagesByID[rowID] = "Auto-repairing a stale Power Metrics channel."
        sample()

        let registrar = PowerMetricsServiceRegistrar()
        registrar.registerIfNeeded(forceRefresh: true) { [weak self] result in
            self?.finishAction(
                for: actionID,
                result: result.mapError { $0 as Error },
                successMessage: "Power Metrics was automatically refreshed after a stale sample window.",
                operation: .installOrRepair,
                serviceKind: .powerMetrics
            )
        }
    }

    /// Reacts to changes in `SMAppService.status` between samples. The two cases we care about:
    /// - A transition into `.enabled` (the user toggled approval on after a reboot/update). We
    ///   silently re-run `registerIfNeeded` so the daemon socket is opened and the ping confirms
    ///   reachability, then clear any stale UI message so the row goes green without an app
    ///   restart.
    /// - Sustained `.notRegistered` (e.g. a fresh boot where launchd has no record). We retry
    ///   registration on a long throttle so we don't hammer BTM. `.requiresApproval` is *not*
    ///   covered here — the user has to approve in System Settings, no amount of background
    ///   retries will help.
    private func handlePowerMetricsApprovalStateChange(
        now: Date,
        previous: PowerMetricsApprovalState?,
        current: PowerMetricsApprovalState
    ) {
        guard PowerMetricsServiceAvailability.isSupportedOS else { return }

        let rowID = serviceIdentifier(for: .powerMetrics)
        let actionID = primaryActionID(for: rowID)

        if current == .enabled, let previous, previous != .enabled {
            powerMetricsLastRegistrationAttemptDate = nil
            if actionMessagesByID[rowID] != nil {
                actionMessagesByID[rowID] = "Approval detected — verifying the Power Metrics helper."
            }
            beginSilentPowerMetricsRegistration(actionID: actionID, rowID: rowID)
            return
        }

        if current == .notRegistered,
           !isServiceActionInFlight(rowID),
           isHelperInstallAvailable(for: .powerMetrics),
           shouldAttemptThrottledRegistration(now: now) {
            powerMetricsLastRegistrationAttemptDate = now
            beginSilentPowerMetricsRegistration(actionID: actionID, rowID: rowID)
        }
    }

    private func shouldAttemptThrottledRegistration(now: Date) -> Bool {
        guard let last = powerMetricsLastRegistrationAttemptDate else { return true }
        return now.timeIntervalSince(last) >= powerMetricsRegistrationRetryInterval
    }

    /// Runs `registerIfNeeded` without claiming the action-in-flight UI state, so the row keeps
    /// its current status while we silently verify reachability. Used for both
    /// post-approval transitions and the throttled `.notRegistered` retry.
    private func beginSilentPowerMetricsRegistration(actionID: String, rowID: String) {
        guard !isServiceActionInFlight(rowID) else { return }

        let registrar = PowerMetricsServiceRegistrar()
        registrar.registerIfNeeded(forceRefresh: false) { [weak self] result in
            self?.samplingQueue.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.actionMessagesByID.removeValue(forKey: rowID)
                case .failure:
                    break
                }
                self.sample()
            }
        }
    }

    func performDetailAction(for actionID: String) {
        let rowID = serviceID(for: actionID)
        guard let descriptor = descriptors().first(where: { $0.id == rowID }) else { return }
        performServiceAction(actionID: actionID, descriptor: descriptor, operation: operation(for: actionID))
    }

    func performPrimaryAction(for rowID: String) {
        guard let descriptor = descriptors().first(where: { $0.id == rowID }) else { return }
        performServiceAction(actionID: primaryActionID(for: rowID), descriptor: descriptor, operation: .installOrRepair)
    }

    private func performServiceAction(
        actionID: String,
        descriptor: ServiceDescriptor,
        operation: ServiceOperation
    ) {
        let rowID = descriptor.id
        samplingQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isServiceActionInFlight(rowID) else { return }

            switch operation {
            case .installOrRepair:
                let isInstallAvailable: Bool = {
                    switch descriptor.kind {
                    case .powerMetrics:
                        return PowerMetricsServiceAvailability.isSupportedOS && self.isHelperInstallAvailable(for: descriptor.kind)
                    default:
                        return self.isHelperInstallAvailable(for: descriptor.kind)
                    }
                }()
                guard isInstallAvailable else { return }
            case .uninstall:
                guard self.isUninstallAvailable(for: descriptor.kind) else { return }
            }

            self.actionInFlightIDs.insert(actionID)
            self.actionMessagesByID[rowID] = self.progressMessage(for: descriptor.kind, operation: operation)
            self.sample()

            switch operation {
            case .installOrRepair:
                self.performInstallOrRepairAction(actionID: actionID, descriptor: descriptor)
            case .uninstall:
                self.performUninstallAction(actionID: actionID, descriptor: descriptor)
            }
        }
    }

    private func performInstallOrRepairAction(actionID: String, descriptor: ServiceDescriptor) {
        switch descriptor.kind {
        case .hardwareAgent:
            let registrar = HardwareMonitoringServiceRegistrar()
            let successMessage = hardwareAgentSuccessMessage()
            registrar.registerIfNeeded(forceRefresh: true) { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result.mapError { $0 as Error },
                    successMessage: successMessage,
                    operation: .installOrRepair,
                    serviceKind: descriptor.kind
                )
            }
        case .audioAgent:
            let registrar = AudioRoutingServiceRegistrar()
            registrar.registerIfNeeded(forceRefresh: true) { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result.mapError { $0 as Error },
                    successMessage: "Audio agent registration refreshed.",
                    operation: .installOrRepair,
                    serviceKind: descriptor.kind
                )
            }
        case .powerMetrics:
            if #available(macOS 13.0, *),
               powerMetricsApprovalState() == .requiresApproval {
                performPowerMetricsApprovalAction(actionID: actionID, descriptor: descriptor)
                return
            }
            let registrar = PowerMetricsServiceRegistrar()
            registrar.registerIfNeeded(forceRefresh: true) { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result.mapError { $0 as Error },
                    successMessage: PowerMetricsServiceAvailability.usesSMJobBless
                        ? "Power metrics helper was reinstalled and re-blessed."
                        : "Power metrics helper registration refreshed.",
                    operation: .installOrRepair,
                    serviceKind: descriptor.kind
                )
            }
        case .audioDriver:
            let installer = AudioRoutingDriverInstaller()
            installer.installIfNeeded { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result,
                    successMessage: "FireWireNetBridge driver installed to /Library/Audio/Plug-Ins/HAL and coreaudiod was restarted.",
                    operation: .installOrRepair,
                    serviceKind: descriptor.kind
                )
            }
        case .virtualCameraDriver:
            performVirtualCameraDriverAction(
                actionID: actionID,
                expectedInstalledState: true,
                fallbackError: "Virtual camera driver installation did not complete."
            ) {
                VirtualCameraDriverService.shared.installDriver()
            }
        }
    }

    @available(macOS 13.0, *)
    private func performPowerMetricsApprovalAction(actionID: String, descriptor: ServiceDescriptor) {
        let rowID = descriptor.id
        let registrar = PowerMetricsServiceRegistrar()
        DispatchQueue.global(qos: .utility).async {
            registrar.surfaceApprovalPromptIfNeeded()
            DispatchQueue.main.async {
                SMAppService.openSystemSettingsLoginItems()
            }
            self.samplingQueue.async { [weak self] in
                guard let self else { return }
                self.actionInFlightIDs.remove(actionID)
                self.actionMessagesByID[rowID] = "Opened Login Items. Toggle PodcastPreview's background item on — the row will refresh on its own once approved."
                self.sample()
            }
        }
    }

    private func performUninstallAction(actionID: String, descriptor: ServiceDescriptor) {
        switch descriptor.kind {
        case .hardwareAgent:
            let registrar = HardwareMonitoringServiceRegistrar()
            registrar.unregister { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result.mapError { $0 as Error },
                    successMessage: "Hardware agent registration was removed.",
                    operation: .uninstall,
                    serviceKind: descriptor.kind
                )
            }
        case .audioAgent:
            let registrar = AudioRoutingServiceRegistrar()
            registrar.unregister { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result.mapError { $0 as Error },
                    successMessage: "Audio agent registration was removed.",
                    operation: .uninstall,
                    serviceKind: descriptor.kind
                )
            }
        case .powerMetrics:
            let registrar = PowerMetricsServiceRegistrar()
            registrar.unregister { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result.mapError { $0 as Error },
                    successMessage: "Power Metrics helper registration was removed.",
                    operation: .uninstall,
                    serviceKind: descriptor.kind
                )
            }
        case .audioDriver:
            let installer = AudioRoutingDriverInstaller()
            installer.uninstallIfPresent { [weak self] result in
                self?.finishAction(
                    for: actionID,
                    result: result,
                    successMessage: "FireWireNetBridge driver was removed and coreaudiod was restarted.",
                    operation: .uninstall,
                    serviceKind: descriptor.kind
                )
            }
        case .virtualCameraDriver:
            performVirtualCameraDriverAction(
                actionID: actionID,
                expectedInstalledState: false,
                fallbackError: "Virtual camera driver uninstall did not complete."
            ) {
                VirtualCameraDriverService.shared.uninstallDriver()
            }
        }
    }

    private func performVirtualCameraDriverAction(
        actionID: String,
        expectedInstalledState: Bool,
        fallbackError: String,
        operation: @escaping () -> Void
    ) {
        DispatchQueue.main.async {
            operation()
            self.waitForVirtualCameraDriverAction(
                actionID: actionID,
                expectedInstalledState: expectedInstalledState,
                fallbackError: fallbackError
            )
        }
    }

    private func waitForVirtualCameraDriverAction(
        actionID: String,
        expectedInstalledState: Bool,
        fallbackError: String
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }

            let service = VirtualCameraDriverService.shared
            if service.actionInProgress {
                self.waitForVirtualCameraDriverAction(
                    actionID: actionID,
                    expectedInstalledState: expectedInstalledState,
                    fallbackError: fallbackError
                )
                return
            }

            let result: Result<Void, Error>
            if service.isInstalled == expectedInstalledState {
                result = .success(())
            } else {
                result = .failure(
                    NSError(
                        domain: "VirtualCameraDriverService",
                        code: expectedInstalledState ? 1 : 2,
                        userInfo: [NSLocalizedDescriptionKey: service.statusMessage.isEmpty ? fallbackError : service.statusMessage]
                    )
                )
            }

            self.finishAction(
                for: actionID,
                result: result,
                successMessage: service.statusMessage.isEmpty ? nil : service.statusMessage,
                operation: expectedInstalledState ? .installOrRepair : .uninstall,
                serviceKind: .virtualCameraDriver
            )
        }
    }

    private func finishAction(
        for actionID: String,
        result: Result<Void, Error>,
        successMessage: String?,
        operation: ServiceOperation,
        serviceKind: ServiceKind
    ) {
        let rowID = serviceID(for: actionID)
        samplingQueue.async { [weak self] in
            guard let self else { return }

            var resolvedResult = result
            if case .success = result {
                let verified = self.verifyLifecycleOutcome(for: serviceKind, operation: operation)
                if !verified {
                    resolvedResult = .failure(self.lifecycleVerificationError(for: serviceKind, operation: operation))
                }
            }

            self.actionInFlightIDs.remove(actionID)
            switch resolvedResult {
            case .success:
                self.actionMessagesByID[rowID] = successMessage ?? self.defaultSuccessMessage(for: serviceKind, operation: operation)
            case .failure(let error):
                self.actionMessagesByID[rowID] = error.localizedDescription
            }
            self.sample()
        }
    }

    private func primaryActionID(for rowID: String) -> String {
        rowID
    }

    private func uninstallActionID(for rowID: String) -> String {
        "\(rowID)-uninstall"
    }

    private func serviceID(for actionID: String) -> String {
        let suffix = "-uninstall"
        guard actionID.hasSuffix(suffix) else { return actionID }
        return String(actionID.dropLast(suffix.count))
    }

    private func operation(for actionID: String) -> ServiceOperation {
        actionID.hasSuffix("-uninstall") ? .uninstall : .installOrRepair
    }

    private func isServiceActionInFlight(_ rowID: String) -> Bool {
        actionInFlightIDs.contains(primaryActionID(for: rowID))
            || actionInFlightIDs.contains(uninstallActionID(for: rowID))
    }

    private func progressMessage(for serviceKind: ServiceKind, operation: ServiceOperation) -> String {
        switch operation {
        case .installOrRepair:
            return "Running \(serviceDisplayName(for: serviceKind)) install/repair. Status will refresh after registration and verification complete."
        case .uninstall:
            return "Running \(serviceDisplayName(for: serviceKind)) uninstall. Status will refresh after removal and process checks complete."
        }
    }

    private func defaultSuccessMessage(for serviceKind: ServiceKind, operation: ServiceOperation) -> String {
        switch operation {
        case .installOrRepair:
            return "\(serviceDisplayName(for: serviceKind)) install/repair completed and was verified."
        case .uninstall:
            return "\(serviceDisplayName(for: serviceKind)) uninstall completed and was verified."
        }
    }

    private func lifecycleVerificationError(
        for serviceKind: ServiceKind,
        operation: ServiceOperation
    ) -> NSError {
        let serviceName = serviceDisplayName(for: serviceKind)
        let description: String
        switch operation {
        case .installOrRepair:
            description = "\(serviceName) install/repair returned, but the expected registered or installed state was not visible after verification. If macOS is showing an approval prompt, approve it and refresh again."
        case .uninstall:
            description = "\(serviceName) uninstall returned, but the service still appears registered, installed, or running after verification. It may need administrator approval, a reboot, or another uninstall attempt."
        }

        return NSError(
            domain: "AppSupportProcessMonitor",
            code: operation == .installOrRepair ? 1 : 2,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    private func verifyLifecycleOutcome(
        for serviceKind: ServiceKind,
        operation: ServiceOperation
    ) -> Bool {
        let delays: [TimeInterval] = [0.0, 0.35, 0.75, 1.5, 3.0]
        for delay in delays {
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            if lifecycleExpectationIsMet(for: serviceKind, operation: operation) {
                return true
            }
        }
        return false
    }

    private func lifecycleExpectationIsMet(
        for serviceKind: ServiceKind,
        operation: ServiceOperation
    ) -> Bool {
        switch operation {
        case .installOrRepair:
            switch serviceKind {
            case .hardwareAgent:
                return registrationState(for: .hardwareAgent) == .known
            case .audioAgent:
                return registrationState(for: .audioAgent) == .known
                    && fetchAudioAgentStatus(timeout: 1.5) != nil
            case .powerMetrics:
                return registrationState(for: .powerMetrics) == .known
            case .audioDriver:
                return FileManager.default.fileExists(atPath: AudioRoutingServiceConstants.installedDriverPath)
                    || Self.isAudioDriverInstalled()
            case .virtualCameraDriver:
                return Self.isVirtualCameraDriverInstalled()
            }
        case .uninstall:
            switch serviceKind {
            case .hardwareAgent:
                return registrationState(for: .hardwareAgent) == .unknown && !isProcessObserved(for: .hardwareAgent)
            case .audioAgent:
                return registrationState(for: .audioAgent) == .unknown && !isProcessObserved(for: .audioAgent)
            case .powerMetrics:
                return registrationState(for: .powerMetrics) == .unknown && !isProcessObserved(for: .powerMetrics)
            case .audioDriver:
                return !FileManager.default.fileExists(atPath: AudioRoutingServiceConstants.installedDriverPath)
            case .virtualCameraDriver:
                return !Self.isVirtualCameraDriverInstalled()
            }
        }
    }

    private func isProcessObserved(for serviceKind: ServiceKind) -> Bool {
        let executableNames: Set<String>
        switch serviceKind {
        case .hardwareAgent:
            executableNames = [
                HardwareMonitoringServiceConstants.modernHelperExecutableName,
                HardwareMonitoringServiceConstants.legacyHelperExecutableName,
                HardwareMonitoringServiceConstants.legacyLaunchAgentHelperExecutableName
            ]
        case .audioAgent:
            executableNames = ["PodcastPreviewAudioAgent"]
        case .powerMetrics:
            executableNames = [
                PowerMetricsServiceConstants.modernHelperBundleID,
                PowerMetricsServiceConstants.legacyHelperBundleID,
                PowerMetricsServiceConstants.activeHelperBundleID
            ]
        case .audioDriver, .virtualCameraDriver:
            executableNames = []
        }
        guard !executableNames.isEmpty else { return false }
        return Self.runningProcessSnapshots().contains { executableNames.contains($0.executableName) }
    }

    private func serviceDisplayName(for serviceKind: ServiceKind) -> String {
        switch serviceKind {
        case .hardwareAgent:
            return "Hardware Agent"
        case .audioAgent:
            return "Audio Agent"
        case .audioDriver:
            return "FireWire Audio Driver"
        case .virtualCameraDriver:
            return "Virtual Camera Driver"
        case .powerMetrics:
            return "Power Metrics"
        }
    }

    private func descriptors() -> [ServiceDescriptor] {
        var items: [ServiceDescriptor] = []

        items.append(
            ServiceDescriptor(
                id: "hardware-agent",
                name: hardwareAgentRowName,
                executableNames: [
                    HardwareMonitoringServiceConstants.modernHelperExecutableName,
                    HardwareMonitoringServiceConstants.legacyHelperExecutableName
                ],
                kind: .hardwareAgent
            )
        )

        items.append(
            ServiceDescriptor(
                id: "audio-agent",
                name: "Audio Agent",
                executableNames: ["PodcastPreviewAudioAgent"],
                kind: .audioAgent
            )
        )

        items.append(
            ServiceDescriptor(
                id: "audio-driver",
                name: "FireWire Audio Driver",
                executableNames: [],
                kind: .audioDriver
            )
        )

        items.append(
            ServiceDescriptor(
                id: "virtual-camera-driver",
                name: "Virtual Camera Driver",
                executableNames: [],
                kind: .virtualCameraDriver
            )
        )

        items.append(
            ServiceDescriptor(
                id: "power-metrics",
                name: "Power Metrics",
                executableNames: [
                    PowerMetricsServiceConstants.modernHelperBundleID,
                    PowerMetricsServiceConstants.legacyHelperBundleID,
                    PowerMetricsServiceConstants.activeHelperBundleID
                ],
                kind: .powerMetrics
            )
        )

        return items
    }

    private func detailText(
        for serviceKind: ServiceKind,
        status: Status,
        registration: RegistrationState,
        context: SampleContext?
    ) -> String {
        var lines: [String] = []

        switch serviceKind {
        case .hardwareAgent:
            let hardwareProcesses = (context?.runningProcesses ?? []).filter {
                $0.executableName == HardwareMonitoringServiceConstants.modernHelperExecutableName
                    || $0.executableName == HardwareMonitoringServiceConstants.legacyHelperExecutableName
            }
            let rootProcessCount = hardwareProcesses.filter(\.isRootOwned).count
            let userProcessCount = hardwareProcesses.filter(\.isUserOwned).count

            guard hardwareAgentUsesSeparateService else {
                lines.append("Hardware monitoring is running inside Podcast Preview instead of a separate background service.")
                lines.append("This mode writes local user-space history and does not rely on the system daemon path.")
                if status == .idle {
                    lines.append("Fresh local hardware samples have not arrived yet.")
                }
                break
            }

            if hardwareAgentUsesSystemDaemonRegistration {
                lines.append("Mode: system daemon.")
            } else if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
                lines.append("Mode: privileged helper.")
            } else {
                lines.append("Mode: per-user launch agent.")
            }

            switch status {
            case .active:
                lines.append("Fresh hardware samples are reaching the app through the \(hardwareAgentServiceDisplayName).")
            case .idle:
                if hardwareAgentUsesPrivilegedRegistration && userProcessCount > 0 && rootProcessCount == 0 {
                    lines.append("A user-session hardware agent was detected, but this OS expects the privileged system path.")
                } else if hardwareAgentUsesPrivilegedRegistration && userProcessCount > 0 {
                    lines.append("The privileged system path is reachable, but a leftover user-session hardware agent was also detected.")
                } else {
                    lines.append("The \(hardwareAgentServiceDisplayName) is registered, but the hardware stream looks stale or unreachable.")
                }
            case .unknown:
                if hardwareAgentUsesPrivilegedRegistration && userProcessCount > 0 {
                    lines.append("A user-session hardware agent was detected, but the expected privileged system path is missing, disabled, or waiting for approval in \(hardwareAgentApprovalLocation).")
                } else {
                    lines.append("The \(hardwareAgentServiceDisplayName) is missing, disabled, or waiting for approval in \(hardwareAgentApprovalLocation).")
                }
            }

            if hardwareAgentUsesPrivilegedRegistration {
                lines.append("When this path is active, the app reads live and historical hardware data over privileged XPC instead of writing its own user-space hardware database.")
            } else {
                lines.append("On this OS, the app talks to the per-user helper instead of the privileged system path.")
            }

            if let migrationAssessment = context?.hardwareHistoryMigration,
               hardwareAgentUsesPrivilegedRegistration {
                lines.append(contentsOf: hardwareHistoryMigrationDetailLines(from: migrationAssessment))
            }
        case .audioAgent:
            if let audioStatus = context?.audioStatus {
                if audioStatus.isRouteRunning {
                    lines.append("The audio routing helper is reachable and the loopback route is running.")
                } else {
                    lines.append("The audio routing helper is reachable, but the loopback route is idle.")
                }
                if !audioStatus.activeOutputDeviceUID.isEmpty {
                    lines.append("Output device: \(audioStatus.activeOutputDeviceUID)")
                }
            } else {
                switch status {
                case .active:
                    lines.append("The audio routing helper is responding.")
                case .idle:
                    if usesLegacyAudioAgentRegistration {
                        lines.append("The audio helper LaunchAgent is installed for this user, but the helper is not responding yet.")
                    } else {
                        lines.append("The launch agent is registered, but the audio helper is not responding yet.")
                    }
                case .unknown:
                    if usesLegacyAudioAgentRegistration {
                        lines.append("The audio helper is not installed for this user yet. Install will copy a LaunchAgent into ~/Library/LaunchAgents and load it for the current session.")
                    } else {
                        lines.append("The audio helper is missing, disabled, or waiting for approval in Login Items.")
                    }
                }
            }
        case .audioDriver:
            if status == .active {
                lines.append("The FireWireNetBridge audio driver is installed and visible to the system as a CoreAudio HAL device.")
            } else if Self.isBundledAudioDriverAvailable() {
                lines.append("The FireWireNetBridge HAL driver is bundled with the app but not yet installed into /Library/Audio/Plug-Ins/HAL.")
            } else {
                lines.append("The FireWireNetBridge driver bundle is not embedded in this app build.")
            }
        case .virtualCameraDriver:
            if status == .active {
                lines.append("The PodcastPreview virtual camera DAL bundle is installed and camera clients can rediscover it after the background camera assistants refresh.")
            } else if Self.isBundledVirtualCameraDriverAvailable() {
                lines.append("The PodcastPreview virtual camera DAL bundle is bundled with the app but not yet installed into /Library/CoreMediaIO/Plug-Ins/DAL.")
            } else {
                lines.append("The PodcastPreview virtual camera driver payload is not embedded in this app build.")
            }
        case .powerMetrics:
            let powerProcesses = (context?.runningProcesses ?? []).filter {
                $0.executableName == PowerMetricsServiceConstants.modernHelperBundleID
                    || $0.executableName == PowerMetricsServiceConstants.legacyHelperBundleID
                    || $0.executableName == PowerMetricsServiceConstants.activeHelperBundleID
            }
            lines.append("Registration: \(registration == .known ? "known" : "unknown").")
            lines.append("Launchd process: \(powerProcesses.isEmpty ? "not observed" : "observed").")
            lines.append("XPC ping: \(context?.powerMetricsHealth.isXPCReachable == true ? "reachable" : "unreachable").")

            if let helperSnapshot = context?.powerMetricsHealth.helperSnapshot {
                if let lastSampleDate = helperSnapshot.lastSampleDate {
                    lines.append("Last daemon sample: \(Self.relativeAgeText(since: lastSampleDate)).")
                }
                if let lastUsableSampleDate = helperSnapshot.lastUsableSampleDate {
                    lines.append("Last usable daemon sample: \(Self.relativeAgeText(since: lastUsableSampleDate)).")
                } else {
                    lines.append("Last usable daemon sample: none yet.")
                }
                if helperSnapshot.consecutiveFailureCount > 0 {
                    lines.append("Consecutive daemon sample failures: \(helperSnapshot.consecutiveFailureCount).")
                }
                if let lastFailureReason = helperSnapshot.lastFailureReason, !lastFailureReason.isEmpty {
                    lines.append("Failure reason: \(lastFailureReason).")
                }
            }

            switch status {
            case .active:
                lines.append("The power metrics helper is returning usable privileged sample data.")
            case .idle:
                switch context?.powerMetricsHealth.sampleState {
                case .respondedWithoutUsableSample:
                    lines.append("The helper responded, but the returned sample did not decode into usable power or per-core frequency readings.")
                default:
                    lines.append("The helper is registered but has not responded to a recent health check.")
                }
            case .unknown:
                switch lastPowerMetricsApprovalState ?? powerMetricsApprovalState() {
                case .requiresApproval:
                    lines.append("macOS is waiting for you to approve PodcastPreview's background item. Click Allow in Settings to open Login Items and toggle it on — the row will go green on its own once approved.")
                case .notRegistered:
                    lines.append("The privileged helper is not registered with launchd yet. Click Install to register; macOS may prompt you to approve a new background item.")
                case .unsupported:
                    lines.append("The privileged helper is not supported on this OS or build.")
                case .enabled:
                    lines.append("The privileged helper is enabled but not yet reachable. It should come online shortly.")
                }
            }

            if PowerMetricsServiceAvailability.usesSMJobBless {
                lines.append("Reinstall removes the existing blessed helper before re-blessing the bundled copy, which is the safest recovery path after a stale or bad binary.")
            }
        }

        if registration == .unknown && serviceKind != .audioDriver && usesModernServiceManagement(for: serviceKind) {
            lines.append("Unknown can also mean the embedded helper is present but not yet trusted by Service Management.")
        }
        if let actionMessage = actionMessagesByID[serviceIdentifier(for: serviceKind)], !actionMessage.isEmpty {
            lines.append(actionMessage)
        }

        return lines.joined(separator: " ")
    }

    private func action(
        for serviceKind: ServiceKind,
        rowID: String,
        currentStatus: Status
    ) -> RowAction? {
        if serviceKind == .hardwareAgent && !hardwareAgentUsesSeparateService {
            return nil
        }

        let title: String
        let isEnabled: Bool

        switch serviceKind {
        case .hardwareAgent:
            if hardwareAgentUsesPrivilegedRegistration,
               let migrationAssessment = hardwareHistoryMigrationAssessment,
               migrationAssessment.hasImportableSources {
                title = currentStatus == .active
                    ? (migrationAssessment.needsImport ? "Repair & Merge" : "Repair")
                    : (migrationAssessment.needsImport ? "Install & Migrate" : "Install")
            } else {
                title = currentStatus == .active ? "Repair" : "Install"
            }
            isEnabled = isHelperInstallAvailable(for: serviceKind)
        case .audioAgent:
            title = currentStatus == .active ? "Repair" : "Install"
            isEnabled = isHelperInstallAvailable(for: serviceKind)
        case .powerMetrics:
            if PowerMetricsServiceAvailability.usesSMJobBless,
               PowerMetricsServiceAvailability.isLegacyPrivilegedHelperInstalled {
                title = "Reinstall"
            } else if lastPowerMetricsApprovalState == .requiresApproval {
                title = "Allow in Settings"
            } else {
                title = currentStatus == .active ? "Repair" : "Install"
            }
            isEnabled = PowerMetricsServiceAvailability.isSupportedOS && isHelperInstallAvailable(for: serviceKind)
        case .audioDriver:
            title = currentStatus == .active ? "Repair" : "Install"
            isEnabled = Self.isBundledAudioDriverAvailable()
        case .virtualCameraDriver:
            title = currentStatus == .active ? "Repair" : "Install"
            isEnabled = Self.isBundledVirtualCameraDriverAvailable()
        }

        return RowAction(
            id: primaryActionID(for: rowID),
            title: title,
            inProgressTitle: ServiceOperation.installOrRepair.progressTitle(for: title),
            isEnabled: isEnabled && !isServiceActionInFlight(rowID),
            isInProgress: actionInFlightIDs.contains(primaryActionID(for: rowID))
        )
    }

    private func uninstallAction(
        for serviceKind: ServiceKind,
        rowID: String,
        currentStatus: Status
    ) -> RowAction? {
        if serviceKind == .hardwareAgent && !hardwareAgentUsesSeparateService {
            return nil
        }

        let actionID = uninstallActionID(for: rowID)
        let isInstalledOrRegistered = currentStatus != .unknown || registrationState(for: serviceKind) == .known
        let isEnabled = isInstalledOrRegistered && isUninstallAvailable(for: serviceKind) && !isServiceActionInFlight(rowID)

        return RowAction(
            id: actionID,
            title: "Uninstall",
            inProgressTitle: ServiceOperation.uninstall.progressTitle(for: "Uninstall"),
            isEnabled: isEnabled,
            isInProgress: actionInFlightIDs.contains(actionID)
        )
    }

    private func isHelperInstallAvailable(for serviceKind: ServiceKind) -> Bool {
        switch serviceKind {
        case .hardwareAgent:
            guard hardwareAgentUsesSeparateService else { return false }
            if hardwareAgentUsesSystemDaemonRegistration {
                return Self.isBundledHelperInstalled(named: HardwareMonitoringServiceConstants.modernHelperExecutableName)
                    && Self.isBundledLaunchDaemonAvailable(named: HardwareMonitoringServiceConstants.modernDaemonPlistName)
            }
            if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
                return Self.isBundledHelperInstalled(named: HardwareMonitoringServiceConstants.legacyHelperExecutableName)
            }
            return isBundledLaunchAgentAvailable(
                helperExecutableName: HardwareMonitoringServiceConstants.legacyLaunchAgentHelperExecutableName,
                serviceKind: serviceKind
            )
        case .audioAgent:
            return isBundledLaunchAgentAvailable(
                helperExecutableName: "PodcastPreviewAudioAgent",
                serviceKind: serviceKind
            )
        case .powerMetrics:
            return Self.isBundledHelperInstalled(named: PowerMetricsServiceConstants.activeHelperBundleID)
                || Self.isBundledHelperInstalled(named: PowerMetricsServiceConstants.modernHelperBundleID)
                || Self.isBundledHelperInstalled(named: PowerMetricsServiceConstants.legacyHelperBundleID)
        case .audioDriver:
            return Self.isBundledAudioDriverAvailable()
        case .virtualCameraDriver:
            return Self.isBundledVirtualCameraDriverAvailable()
        }
    }

    private func isUninstallAvailable(for serviceKind: ServiceKind) -> Bool {
        switch serviceKind {
        case .hardwareAgent:
            return hardwareAgentUsesSeparateService && registrationState(for: .hardwareAgent) == .known
        case .audioAgent:
            return registrationState(for: .audioAgent) == .known
        case .powerMetrics:
            return PowerMetricsServiceAvailability.isSupportedOS && registrationState(for: .powerMetrics) == .known
        case .audioDriver:
            return FileManager.default.fileExists(atPath: AudioRoutingServiceConstants.installedDriverPath) || Self.isAudioDriverInstalled()
        case .virtualCameraDriver:
            return Self.isVirtualCameraDriverInstalled()
        }
    }

    private func serviceIdentifier(for serviceKind: ServiceKind) -> String {
        switch serviceKind {
        case .hardwareAgent:
            return "hardware-agent"
        case .audioAgent:
            return "audio-agent"
        case .audioDriver:
            return "audio-driver"
        case .virtualCameraDriver:
            return "virtual-camera-driver"
        case .powerMetrics:
            return "power-metrics"
        }
    }

    private func makeRow(
        for descriptor: ServiceDescriptor,
        context: SampleContext
    ) -> Row {
        if descriptor.kind == .hardwareAgent {
            return makeHardwareAgentRow(for: descriptor, context: context)
        }

        if descriptor.kind == .audioDriver {
            return makeAudioDriverRow(isDriverPresent: context.audioDriverPresent)
        }

        if descriptor.kind == .virtualCameraDriver {
            return makeVirtualCameraDriverRow(isDriverPresent: context.virtualCameraDriverPresent)
        }

        let registration = registrationState(for: descriptor.kind)
        let process = context.runningProcesses.first(where: {
            descriptor.executableNames.contains($0.executableName)
        })
        let isReachable = serviceResponding(for: descriptor.kind, registration: registration, context: context)
        let status: Status = {
            if isReachable {
                return .active
            }
            switch registration {
            case .known:
                return .idle
            case .unknown:
                return .unknown
            }
        }()

        let statusLabel = powerMetricsStatusLabel(for: descriptor.kind, status: status)

        return Row(
            id: descriptor.id,
            name: descriptor.name,
            status: status,
            uptimeText: process?.uptimeText ?? "—",
            statusLabel: statusLabel,
            detailText: detailText(for: descriptor.kind, status: status, registration: registration, context: context),
            action: action(for: descriptor.kind, rowID: descriptor.id, currentStatus: status),
            uninstallAction: uninstallAction(for: descriptor.kind, rowID: descriptor.id, currentStatus: status)
        )
    }

    private func powerMetricsStatusLabel(for serviceKind: ServiceKind, status: Status) -> String? {
        guard serviceKind == .powerMetrics, status == .unknown else { return nil }
        switch lastPowerMetricsApprovalState ?? powerMetricsApprovalState() {
        case .requiresApproval:
            return "Approval Needed"
        case .notRegistered:
            return "Not Registered"
        case .unsupported:
            return "Unsupported"
        case .enabled:
            return nil
        }
    }

    private func makeHardwareAgentRow(
        for descriptor: ServiceDescriptor,
        context: SampleContext
    ) -> Row {
        if !hardwareAgentUsesSeparateService {
            let status: Status = context.hardwareAgentReachable ? .active : .idle
            return Row(
                id: descriptor.id,
                name: descriptor.name,
                status: status,
                uptimeText: "—",
                statusLabel: "Built-In",
                detailText: detailText(for: descriptor.kind, status: status, registration: .known, context: context),
                action: nil,
                uninstallAction: nil
            )
        }

        let registration = registrationState(for: .hardwareAgent)
        let hardwareProcesses = context.runningProcesses.filter {
            descriptor.executableNames.contains($0.executableName)
        }
        let rootProcesses = hardwareProcesses.filter(\.isRootOwned)
        let userProcesses = hardwareProcesses.filter(\.isUserOwned)
        let preferredProcess = rootProcesses.first ?? userProcesses.first
        let hasUnexpectedUserProcess = hardwareAgentUsesSystemDaemonRegistration && !userProcesses.isEmpty

        let status: Status = {
            if context.hardwareAgentReachable {
                return hasUnexpectedUserProcess ? .idle : .active
            }
            if !hardwareProcesses.isEmpty {
                return .idle
            }
            switch registration {
            case .known:
                return .idle
            case .unknown:
                return .unknown
            }
        }()

        return Row(
            id: descriptor.id,
            name: descriptor.name,
            status: status,
            uptimeText: preferredProcess?.uptimeText ?? "—",
            statusLabel: nil,
            detailText: detailText(for: descriptor.kind, status: status, registration: registration, context: context),
            action: action(for: descriptor.kind, rowID: descriptor.id, currentStatus: status),
            uninstallAction: uninstallAction(for: descriptor.kind, rowID: descriptor.id, currentStatus: status)
        )
    }

    private func makeAudioDriverRow(
        isDriverPresent: Bool
    ) -> Row {
        let status: Status = isDriverPresent ? .active : .idle
        return Row(
            id: "audio-driver",
            name: "FireWire Audio Driver",
            status: status,
            uptimeText: "—",
            statusLabel: isDriverPresent ? "Installed" : "Not Installed",
            detailText: detailText(
                for: .audioDriver,
                status: status,
                registration: isDriverPresent ? .known : .unknown,
                context: nil
            ),
            action: action(for: .audioDriver, rowID: "audio-driver", currentStatus: status),
            uninstallAction: uninstallAction(for: .audioDriver, rowID: "audio-driver", currentStatus: status)
        )
    }

    private func makeVirtualCameraDriverRow(
        isDriverPresent: Bool
    ) -> Row {
        let isBundled = Self.isBundledVirtualCameraDriverAvailable()
        let status: Status = isDriverPresent ? .active : (isBundled ? .idle : .unknown)
        let statusLabel: String = isDriverPresent
            ? "Installed"
            : (isBundled ? "Not Installed" : "Unavailable")

        return Row(
            id: "virtual-camera-driver",
            name: "Virtual Camera Driver",
            status: status,
            uptimeText: "—",
            statusLabel: statusLabel,
            detailText: detailText(
                for: .virtualCameraDriver,
                status: status,
                registration: isDriverPresent ? .known : .unknown,
                context: nil
            ),
            action: action(for: .virtualCameraDriver, rowID: "virtual-camera-driver", currentStatus: status),
            uninstallAction: uninstallAction(for: .virtualCameraDriver, rowID: "virtual-camera-driver", currentStatus: status)
        )
    }

    private func serviceResponding(
        for serviceKind: ServiceKind,
        registration: RegistrationState,
        context: SampleContext
    ) -> Bool {
        guard registration == .known else { return false }

        switch serviceKind {
        case .hardwareAgent:
            return context.hardwareAgentReachable
        case .audioAgent:
            return context.audioStatus != nil
        case .audioDriver:
            return false
        case .virtualCameraDriver:
            return false
        case .powerMetrics:
            return context.powerMetricsHealth.sampleState == .usableSample
        }
    }

    private func waitForHardwareAgentStatus(timeout: TimeInterval = 1.25) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var didRespond = false

        hardwareClient.fetchStatus { snapshot in
            didRespond = snapshot != nil
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            hardwareClient.invalidate()
            return false
        }

        return didRespond
    }

    private func fetchAudioAgentStatus(timeout: TimeInterval = 1.25) -> AudioRoutingStatusSnapshot? {
        let semaphore = DispatchSemaphore(value: 0)
        var response: AudioRoutingStatusSnapshot?

        audioClient.fetchStatus { snapshot in
            response = snapshot
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            audioClient.invalidate()
            return nil
        }

        return response
    }

    private func fetchPowerMetricsHealth(timeout: TimeInterval = 6.0) -> PowerMetricsHealth {
        let healthSemaphore = DispatchSemaphore(value: 0)
        var helperSnapshot: PowerMetricsHealthSnapshot?

        powerClient.fetchHealth { snapshot in
            helperSnapshot = snapshot
            healthSemaphore.signal()
        }

        if healthSemaphore.wait(timeout: .now() + min(2.0, timeout)) == .timedOut {
            powerClient.invalidate()
        }

        let sampleState: PowerMetricsHealth.SampleState
        if helperSnapshot?.lastUsableSampleDate != nil {
            sampleState = .usableSample
        } else if helperSnapshot?.lastSampleDate != nil {
            sampleState = .respondedWithoutUsableSample
        } else {
            sampleState = .unavailable
        }

        return PowerMetricsHealth(sampleState: sampleState, helperSnapshot: helperSnapshot)
    }

    private static func isAudioDriverInstalled() -> Bool {
        AudioRoutingServiceConstants.loopbackDeviceUID.withCString { uid in
            AudioDevices_FindDeviceByUID(uid) != AudioDeviceID(kAudioObjectUnknown)
        }
    }

    private static func isBundledHelperInstalled(named executableName: String) -> Bool {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchServices")
            .appendingPathComponent(executableName)
        return FileManager.default.fileExists(atPath: helperURL.path)
    }

    private static func isBundledAudioDriverAvailable() -> Bool {
        AudioRoutingDriverInstaller.bundledDriverURL() != nil
    }

    private static func isVirtualCameraDriverInstalled() -> Bool {
        VirtualCameraDriverService.installedDriverURL() != nil
    }

    private static func isBundledVirtualCameraDriverAvailable() -> Bool {
        VirtualCameraDriverService.bundledDriverURL() != nil
    }

    private static func isBundledLaunchDaemonAvailable(named plistName: String) -> Bool {
        let plistURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchDaemons")
            .appendingPathComponent(plistName)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func isInstalledLaunchDaemonAvailable(named plistName: String) -> Bool {
        let plistURL = URL(fileURLWithPath: "/Library/LaunchDaemons")
            .appendingPathComponent(plistName)
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    private func isBundledLaunchAgentAvailable(
        helperExecutableName: String,
        serviceKind: ServiceKind
    ) -> Bool {
        guard let descriptor = legacyLaunchAgentDescriptor(for: serviceKind) else {
            return Self.isBundledHelperInstalled(named: helperExecutableName)
        }
        return LegacyUserLaunchAgentSupport.bundledAssetsAvailable(for: descriptor)
    }

    private func registrationState(for serviceKind: ServiceKind) -> RegistrationState {
        switch serviceKind {
        case .hardwareAgent:
            if hardwareAgentUsesLegacyPrivilegedHelperRegistration {
                return HardwareMonitoringServiceAvailability.isLegacyPrivilegedHelperInstalled ? .known : .unknown
            }
            if HardwareMonitoringServiceAvailability.usesLegacyUserLaunchAgent,
               let descriptor = legacyLaunchAgentDescriptor(for: .hardwareAgent) {
                return LegacyUserLaunchAgentSupport.isInstalled(for: descriptor) ? .known : .unknown
            }
            guard #available(macOS 13.0, *) else { return .unknown }
            let service = SMAppService.daemon(plistName: HardwareMonitoringServiceConstants.modernDaemonPlistName)
            switch service.status {
            case .enabled:
                return .known
            case .notRegistered, .requiresApproval, .notFound:
                return .unknown
            @unknown default:
                return .unknown
            }

        case .audioAgent:
            guard let descriptor = legacyLaunchAgentDescriptor(for: .audioAgent),
                  LegacyUserLaunchAgentSupport.isSupportedOnCurrentOS else {
                return .unknown
            }
            return LegacyUserLaunchAgentSupport.isInstalled(for: descriptor) ? .known : .unknown

        case .audioDriver:
            return Self.isAudioDriverInstalled() ? .known : .unknown

        case .virtualCameraDriver:
            return Self.isVirtualCameraDriverInstalled() ? .known : .unknown

        case .powerMetrics:
            return powerMetricsApprovalState() == .enabled ? .known : .unknown
        }
    }

    private func powerMetricsApprovalState() -> PowerMetricsApprovalState {
        guard PowerMetricsServiceAvailability.isSupportedOS else { return .unsupported }
        if PowerMetricsServiceAvailability.usesSMJobBless {
            return PowerMetricsServiceAvailability.isLegacyPrivilegedHelperInstalled ? .enabled : .notRegistered
        }
        guard #available(macOS 13.0, *) else { return .unsupported }

        let service = SMAppService.daemon(plistName: PowerMetricsServiceConstants.modernDaemonPlistName)
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .notRegistered
        @unknown default:
            return .notRegistered
        }
    }

    private func usesModernServiceManagement(for serviceKind: ServiceKind) -> Bool {
        switch serviceKind {
        case .hardwareAgent:
            return hardwareAgentUsesSystemDaemonRegistration
        case .audioAgent, .powerMetrics:
            if #available(macOS 13.0, *) {
                return true
            }
            return false
        case .audioDriver, .virtualCameraDriver:
            return false
        }
    }

    private func hardwareHistoryMigrationAssessmentForCurrentMode() -> HardwareHistoryMigrationAssessment? {
        guard hardwareAgentUsesPrivilegedRegistration else { return nil }
        guard let currentUserRootURL = HardwareHistoryDatabase.userApplicationSupportRootURL() else {
            return nil
        }

        return HardwareHistoryDatabase.assessMigration(
            fromSourceRootURLs: [currentUserRootURL],
            intoRootURL: HardwareHistoryDatabase.localApplicationSupportRootURL()
        )
    }

    private func hardwareAgentSuccessMessage() -> String {
        guard hardwareAgentUsesPrivilegedRegistration,
              let migrationAssessment = hardwareHistoryMigrationAssessmentForCurrentMode() else {
            return "Hardware agent registration refreshed."
        }

        let destinationPath = migrationAssessment.destination.displayPath
        if migrationAssessment.hasImportableSources {
            if migrationAssessment.needsImport {
                return "Hardware agent registration refreshed. Retained user-space hardware history will be merged into \(destinationPath) when the privileged collector starts."
            }
            return "Hardware agent registration refreshed. The privileged hardware store at \(destinationPath) is already in place, and the collector will still check for any newer retained user-space history on launch."
        }

        if migrationAssessment.destination.exists {
            return "Hardware agent registration refreshed. The privileged hardware store at \(destinationPath) is already active."
        }
        return "Hardware agent registration refreshed. The privileged hardware store will be created at \(destinationPath) when the collector starts."
    }

    private func hardwareHistoryMigrationDetailLines(
        from assessment: HardwareHistoryMigrationAssessment
    ) -> [String] {
        let sourcePaths = assessment.sources.map(\.displayPath)
        let destinationPath = assessment.destination.displayPath

        guard !sourcePaths.isEmpty else {
            if assessment.destination.exists {
                return [
                    "The privileged hardware history store is already owned at \(destinationPath)."
                ]
            }
            return [
                "No existing user-space hardware history was detected for migration. The privileged store will be created at \(destinationPath) on first helper launch."
            ]
        }

        let sourceSummary = sourcePaths.joined(separator: ", ")
        if assessment.needsImport {
            return [
                "Install preserves retained hardware history by merging the current user-space store into the privileged database on helper launch.",
                "Source: \(sourceSummary).",
                "Destination: \(destinationPath)."
            ]
        }

        return [
            "The privileged hardware store already exists, and helper launch still re-checks the user-space store for any newer retained rollups before collection continues.",
            "Source: \(sourceSummary).",
            "Destination: \(destinationPath)."
        ]
    }

    private func helperServicesMigrationDetailLines(
        from assessment: HardwareHistoryMigrationAssessment
    ) -> [String] {
        let sourceSummary: String
        if assessment.sources.isEmpty {
            sourceSummary = "No current user-space hardware history store is waiting to be imported."
        } else if assessment.sources.count == 1 {
            sourceSummary = "Current user hardware history source: \(assessment.sources[0].displayPath)."
        } else {
            sourceSummary = "Current user hardware history sources: \(assessment.sources.map(\.displayPath).joined(separator: ", "))."
        }

        let destinationSummary = "Privileged destination: \(assessment.destination.displayPath)."

        if assessment.needsImport {
            return [
                "Install and Repair both keep the existing history path safe by merging retained user-space hardware rollups into the privileged store when the helper starts.",
                sourceSummary,
                destinationSummary
            ]
        }

        return [
            "The privileged hardware history path is already established, and helper launch still checks the current user store for any fresher retained history before resuming collection.",
            sourceSummary,
            destinationSummary
        ]
    }

    private func legacyLaunchAgentDescriptor(for serviceKind: ServiceKind) -> LegacyUserLaunchAgentDescriptor? {
        switch serviceKind {
        case .hardwareAgent:
            return LegacyUserLaunchAgentDescriptor(
                plistName: HardwareMonitoringServiceConstants.legacyLaunchAgentPlistName,
                label: HardwareMonitoringServiceConstants.legacyLaunchAgentLabel,
                helperExecutableName: HardwareMonitoringServiceConstants.legacyLaunchAgentHelperExecutableName
            )
        case .audioAgent:
            return LegacyUserLaunchAgentDescriptor(
                plistName: AudioRoutingServiceConstants.launchAgentPlistName,
                label: AudioRoutingServiceConstants.helperBundleID,
                helperExecutableName: "PodcastPreviewAudioAgent"
            )
        case .audioDriver, .virtualCameraDriver, .powerMetrics:
            return nil
        }
    }

    nonisolated private static func runningProcessSnapshots() -> [ProcessSnapshot] {
        listAllPIDs().compactMap(readProcessSnapshot(pid:))
    }

    nonisolated private static func listAllPIDs() -> [Int32] {
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

    nonisolated private static func readProcessSnapshot(pid: Int32) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }

        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, size)

        var executableName = ""

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathResult = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathResult > 0 {
            executableName = URL(fileURLWithPath: String(cString: pathBuffer)).lastPathComponent
        }

        if executableName.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let nameResult = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            if nameResult > 0 {
                executableName = String(cString: nameBuffer)
            }
        }

        guard !executableName.isEmpty else { return nil }

        let startDate: Date?
        let userID: uid_t?
        if result == size {
            let seconds = TimeInterval(bsdInfo.pbi_start_tvsec)
            let microseconds = TimeInterval(bsdInfo.pbi_start_tvusec) / 1_000_000.0
            startDate = Date(timeIntervalSince1970: seconds + microseconds)
            userID = bsdInfo.pbi_uid
        } else {
            startDate = nil
            userID = nil
        }

        return ProcessSnapshot(pid: pid, executableName: executableName, startDate: startDate, userID: userID)
    }
}
