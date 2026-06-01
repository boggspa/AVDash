import PodcastPreviewShared
import CloudKit
import Foundation
import Combine

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
                        ? "Found \(machineLabel), but no live CloudKit snapshot is available yet. This usually means the Mac published its identity record but failed to save the CurrentSnapshot payload."
                        : "Found \(machineLabel), but no dashboard snapshot is available yet. The Mac is publishing live data, but the full dashboard record has not landed in CloudKit yet."
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
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown bundle"
        let containerID = CompanionCloudKitSchema.containerIdentifier

        if lowercasedMessage.contains("invalid bundle id") || lowercasedMessage.contains("invalid bundle identifier") {
            return "CloudKit rejected this build because \(bundleID) is not enabled for \(containerID). Enable iCloud/CloudKit for this App ID, add the container, then regenerate and reinstall the provisioning profile."
        }

        if let cloudKitError = error as? CKError {
            switch cloudKitError.code {
            case .notAuthenticated:
                return "iCloud is not signed in for this device. Sign in to iCloud, enable iCloud Drive/CloudKit access, then refresh."
            case .permissionFailure:
                return "CloudKit denied access for \(bundleID). Check that the provisioning profile includes \(containerID) and that this App ID is attached to the container."
            default:
                break
            }
        }

        return rawMessage
    }

    private func refreshSelectedMachineDetails() async {
        guard let selectedMachineID else {
            historyMirror.reset()
            return
        }

        do {
            try await historyMirror.refresh(machineID: selectedMachineID, snapshotStore: snapshotStore)
        } catch {
            lastErrorMessage = userFacingCloudKitMessage(for: error)
        }
    }
}
