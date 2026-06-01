import PodcastPreviewShared
import CloudKit
import Foundation
import Combine
import OSLog

@MainActor
final class CloudKitCompanionStore: ObservableObject {
    @Published var snapshots: [CompanionDashboardSnapshot] = []
    @Published var currentSnapshots: [CompanionCurrentSnapshotPayload] = []
    @Published var machines: [CompanionMachineIdentity] = []
    @Published var selectedMachineID: String?
    @Published var isLoading = false
    @Published var lastErrorMessage: String?

    let historyMirror = CloudKitHistoryMirror()

    private let database: CKDatabase
    private let machineListStore: CloudKitMachineListStore
    private let snapshotStore: CloudKitMachineSnapshotStore
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.chrisizatt.PodcastPreview.Companion.iOS",
        category: "CloudKitCompanion"
    )
    private var autoRefreshTask: Task<Void, Never>?

    init(container: CKContainer = CKContainer(identifier: CompanionCloudKitSchema.containerIdentifier)) {
        self.database = container.privateCloudDatabase
        self.machineListStore = CloudKitMachineListStore(database: database)
        self.snapshotStore = CloudKitMachineSnapshotStore(database: database)
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    var selectedCurrentSnapshot: CompanionCurrentSnapshotPayload? {
        if let selectedMachineID {
            return currentSnapshots.first(where: { $0.id == selectedMachineID })
        }
        return currentSnapshots.first
    }

    var selectedSnapshot: CompanionDashboardSnapshot? {
        if let selectedMachineID {
            return snapshots.first(where: { $0.machineIdentity.machineID == selectedMachineID })
        }
        return snapshots.first
    }

    func selectMachine(_ machineID: String) {
        selectedMachineID = machineID
        Task { [weak self] in
            await self?.refreshSelectedMachineDetails()
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        lastErrorMessage = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                let machines = try await machineListStore.loadMachines()
                let loadedCurrentSnapshots = try await snapshotStore.loadCurrentSnapshotPayloads(
                    machineIDs: machines.map(\.machineID)
                )
                let loadedDashboards = try await snapshotStore.loadDashboards(machineIDs: machines.map(\.machineID))
                let currentSnapshots = loadedCurrentSnapshots.sorted { $0.updatedAt > $1.updatedAt }
                let snapshots = loadedDashboards.sorted { $0.updatedAt > $1.updatedAt }

                self.machines = machines
                self.currentSnapshots = currentSnapshots
                self.snapshots = snapshots

                if currentSnapshots.isEmpty || snapshots.isEmpty {
                    self.historyMirror.reset()

                    if machines.isEmpty {
                        self.lastErrorMessage = nil
                    } else {
                        let machineLabel = machines.count == 1 ? "source Mac" : "\(machines.count) source Macs"
                        self.lastErrorMessage = currentSnapshots.isEmpty
                        ? "Found \(machineLabel), but no live snapshot has arrived yet. Open AVDash on the Mac and confirm iOS Companion Sync is enabled."
                        : "Found \(machineLabel), but detailed history has not finished syncing yet. Keep AVDash open on the Mac and refresh."
                    }

                    self.isLoading = false
                    return
                }

                // Don't auto-select machine - let user choose from selection screen
                if let selectedMachineID,
                   machines.contains(where: { $0.machineID == selectedMachineID }) == false {
                    self.selectedMachineID = nil
                    self.historyMirror.reset()
                }

                await refreshSelectedMachineDetails()
            } catch {
                self.logCloudKitError(error, context: "refresh")
                self.currentSnapshots = []
                self.snapshots = []
                self.machines = []
                self.selectedMachineID = nil
                self.historyMirror.reset()
                self.lastErrorMessage = self.userFacingCloudKitMessage(for: error)
            }

            self.isLoading = false
        }
    }

    func startAutoRefresh(every interval: TimeInterval = 15) {
        guard autoRefreshTask == nil else { return }

        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    break
                }

                guard let self else { break }
                await MainActor.run {
                    self.refresh()
                }
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func userFacingCloudKitMessage(for error: Error) -> String {
        let rawMessage = error.localizedDescription
        let lowercasedMessage = rawMessage.lowercased()

        if lowercasedMessage.contains("invalid bundle id") || lowercasedMessage.contains("invalid bundle identifier") {
            return "This build is not connected to the AVDash iCloud container. Install the latest TestFlight or App Store build, then refresh."
        }

        if let cloudKitError = error as? CKError {
            switch cloudKitError.code {
            case .notAuthenticated:
                return "Sign in to iCloud on this device, then reopen AVDash and refresh."
            case .permissionFailure:
                return "This build does not have access to the AVDash iCloud container. Install the latest TestFlight or App Store build, then refresh."
            case .networkUnavailable, .networkFailure:
                return "AVDash cannot reach iCloud right now. Check the network connection, then refresh."
            case .serviceUnavailable, .requestRateLimited:
                return "iCloud is temporarily unavailable. Wait a moment, then refresh."
            case .quotaExceeded:
                return "iCloud storage is full for this account. Free up iCloud storage, then refresh."
            default:
                break
            }
        }

        return "AVDash could not load iCloud companion data. Check iCloud and network status, then refresh."
    }

    private func logCloudKitError(_ error: Error, context: String) {
        logger.error("CloudKit \(context, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }

    private func refreshSelectedMachineDetails() async {
        guard let selectedMachineID else {
            historyMirror.reset()
            return
        }

        do {
            try await historyMirror.refresh(machineID: selectedMachineID, snapshotStore: snapshotStore)
        } catch {
            logCloudKitError(error, context: "history refresh")
            lastErrorMessage = userFacingCloudKitMessage(for: error)
        }
    }
}
