//
//  RemoteHardwareManager.swift
//  PodcastPreview
//
//  Manages discovery of remote Macs on the local network and maintains
//  connections to approved machines for hardware telemetry streaming.
//  Also handles optional CloudKit synchronization for the iOS Companion app.
//

import Foundation
import Combine
import IOKit
import PodcastPreviewCore
import PodcastPreviewShared

@MainActor
final class RemoteHardwareManager: ObservableObject {
    static let shared = RemoteHardwareManager()

    private static let companionSyncEnabledKey = "PodcastPreview.RemoteHardware.CompanionSyncEnabled"

    // MARK: - Published State

    @Published private(set) var discoveredMachines: [RemoteMonitoringClient.DiscoveredMachine] = []
    @Published private(set) var connectedMachines: [RemoteMachineConnection] = []
    @Published private(set) var approvedHosts: [String: String] = [:]
    @Published private(set) var localConnectedHosts: [RemoteMonitoringServer.ConnectedHost] = []
    @Published private(set) var localPendingAuthRequest: RemoteMonitoringServer.PendingAuthRequest?
    @Published private(set) var localListeningPort: UInt16?
    @Published private(set) var localServerIsRunning = false
    @Published private(set) var localServerPasscode: String
    @Published var selectedMachineID: String?

    // Companion Sync State
    @Published var isCompanionSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCompanionSyncEnabled, forKey: Self.companionSyncEnabledKey)
            updateCloudSyncService()
        }
    }
    @Published private(set) var cloudLastPublishedAt: Date?
    @Published private(set) var cloudLastErrorMessage: String?

    // MARK: - Private State

    private let client: RemoteMonitoringClient
    private let localServer: RemoteMonitoringServer
    private let localMachineIdentity: RemoteMachineIdentity
    private var cloudSyncService: CloudHardwareSyncService?
    private var cancellables = Set<AnyCancellable>()
    private lazy var localCollectorService = HardwareCollectorService(
        powerMetricsProvider: AppPowerMetricsProvider.live,
        appGPUUsageProvider: AppGPUUsageProvider.live,
        runningApplicationProvider: AppRunningApplicationProvider.live
    )

    private init() {
        let localMachineIdentity = Self.buildLocalIdentity()
        self.localMachineIdentity = localMachineIdentity
        self.localServer = RemoteMonitoringServer(machineIdentity: localMachineIdentity)
        self.localServerPasscode = localServer.currentPasscode

        self.isCompanionSyncEnabled = UserDefaults.standard.bool(forKey: Self.companionSyncEnabledKey)

        self.client = RemoteMonitoringClient()

        // Bridge client's published properties
        client.$discoveredServers
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredMachines)

        client.$connections
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectedMachines)

        localServer.$isRunning
            .receive(on: DispatchQueue.main)
            .assign(to: &$localServerIsRunning)

        localServer.$currentPasscode
            .receive(on: DispatchQueue.main)
            .assign(to: &$localServerPasscode)

        localServer.$listeningPort
            .receive(on: DispatchQueue.main)
            .assign(to: &$localListeningPort)

        localServer.$connectedHosts
            .receive(on: DispatchQueue.main)
            .assign(to: &$localConnectedHosts)

        localServer.$pendingAuthRequest
            .receive(on: DispatchQueue.main)
            .assign(to: &$localPendingAuthRequest)

        refreshApprovedHosts()
        updateCloudSyncService()
    }

    // MARK: - Discovery

    func startDiscovery() {
        client.startScanning()
    }

    func stopDiscovery() {
        client.stopScanning()
    }

    // MARK: - Local Sharing

    var localMachineName: String {
        localMachineIdentity.displayName
    }

    var localMachineSubtitle: String {
        [localMachineIdentity.chipType, localMachineIdentity.modelIdentifier]
            .compactMap { $0 }
            .first ?? "Mac"
    }

    func startSharingThisMac() {
        localServer.start(collectorService: localCollectorService)
    }

    func stopSharingThisMac() {
        localServer.stop()
    }

    func rotateLocalPasscode() {
        localServer.rotatePasscode()
    }

    func approvePendingRequest(_ request: RemoteMonitoringServer.PendingAuthRequest, remember: Bool) {
        localServer.approveAuth(request, remember: remember)
        refreshApprovedHosts()
    }

    func denyPendingRequest(_ request: RemoteMonitoringServer.PendingAuthRequest) {
        localServer.denyAuth(request)
    }

    func disconnectLocalHost(_ machineID: String) {
        localServer.disconnectHost(machineID)
    }

    func revokeApprovedHost(_ machineID: String) {
        RemoteAuthKeychain.revokeApproval(hostMachineID: machineID)
        localServer.disconnectHost(machineID)
        refreshApprovedHosts()
    }

    func refreshApprovedHosts() {
        approvedHosts = RemoteAuthKeychain.allApprovedHosts()
    }

    // MARK: - Cloud Sync

    private func updateCloudSyncService() {
        if isCompanionSyncEnabled {
            if cloudSyncService == nil {
                let service = CloudHardwareSyncService(
                    machineIdentity: localMachineIdentity,
                    collectorService: localCollectorService,
                    historyReader: localCollectorService.historyReader,
                    processHistoryReader: localCollectorService.processHistoryReader,
                    eventReader: localCollectorService.eventReader,
                    insightsService: localCollectorService.insightsService
                )

                service.$lastPublishedAt
                    .receive(on: DispatchQueue.main)
                    .assign(to: &$cloudLastPublishedAt)

                service.$lastErrorMessage
                    .receive(on: DispatchQueue.main)
                    .assign(to: &$cloudLastErrorMessage)

                cloudSyncService = service
            }
            cloudSyncService?.start()
        } else {
            cloudSyncService?.stop()
        }
    }

    // MARK: - Connections

    func connect(to machine: RemoteMonitoringClient.DiscoveredMachine, passcode: String) {
        _ = client.connect(to: machine, passcode: passcode)
    }

    func connectByAddress(_ address: String, port: UInt16, passcode: String) {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAddress.isEmpty else { return }
        _ = client.connect(
            toHost: normalizedAddress,
            port: port,
            passcode: passcode,
            displayName: normalizedAddress
        )
    }

    func disconnect(machineID: String) {
        if let connection = client.connections.first(where: { $0.id == machineID }) {
            client.disconnect(connection)
        }
        if selectedMachineID == machineID {
            selectedMachineID = nil
        }
    }

    func connection(for machineID: String) -> RemoteMachineConnection? {
        client.connections.first(where: { $0.id == machineID })
    }

    // MARK: - Helpers

    private static func buildLocalIdentity() -> RemoteMachineIdentity {
        RemoteMachineIdentity(
            machineID: localMachineID(),
            displayName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            modelIdentifier: modelIdentifier(),
            cpuName: cpuBrandString(),
            totalRAMGB: totalRAMGB(),
            macOSVersion: RemoteSystemDisplayFormatter.macOSDisplayString(version: ProcessInfo.processInfo.operatingSystemVersion),
            chipType: chipType()
        )
    }

    private static func localMachineID() -> String {
        // Use the hardware UUID as a stable machine identifier
        let platformExpert = IOServiceGetMatchingService(
            kIOMasterPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        if platformExpert != 0 {
            defer { IOObjectRelease(platformExpert) }
            if let uuid = IORegistryEntryCreateCFProperty(
                platformExpert,
                kIOPlatformUUIDKey as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String {
                return uuid
            }
        }
        return RemoteMachineIDStore.persistentFallbackMachineID()
    }

    private static func modelIdentifier() -> String {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            defer { IOObjectRelease(service) }

            if let model = IORegistryEntryCreateCFProperty(
                service,
                "model" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? Data {
                return String(data: model, encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters) ?? "Mac"
            }
        }
        return "Mac"
    }

    private static func cpuBrandString() -> String? {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        return String(cString: brand)
    }

    private static func totalRAMGB() -> Double {
        var size: UInt64 = 0
        let mibCount = 2
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        var dataSize = MemoryLayout<UInt64>.size
        sysctl(&mib, UInt32(mibCount), &size, &dataSize, nil, 0)
        return Double(size) / (1024 * 1024 * 1024)
    }

    private static func chipType() -> String? {
        var size = 0
        sysctlbyname("hw.targettype", nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.targettype", &buf, &size, nil, 0)
        let target = String(cString: buf)
        return target.isEmpty ? nil : target
    }
}
