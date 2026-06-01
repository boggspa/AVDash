//
//  CompanionServerModel.swift
//  PodcastPreviewCompanion
//
//  Coordinates the RemoteMonitoringServer with the companion UI.
//

import Foundation
import Combine
import IOKit
import PodcastPreviewCore

@MainActor
final class CompanionServerModel: ObservableObject {
    let server: RemoteMonitoringServer
    private let collectorService: HardwareCollectorService
    private let cloudSyncService: CloudHardwareSyncService
    private var cancellables = Set<AnyCancellable>()

    @Published var approvedHosts: [String: String] = [:]

    init() {
        let identity = Self.buildLocalIdentity()
        self.server = RemoteMonitoringServer(machineIdentity: identity)
        self.collectorService = HardwareCollectorService()
        self.cloudSyncService = CloudHardwareSyncService(
            machineIdentity: CompanionMachineIdentity(
                machineID: identity.machineID,
                displayName: identity.displayName,
                modelIdentifier: identity.modelIdentifier,
                cpuName: identity.cpuName,
                totalRAMGB: identity.totalRAMGB,
                macOSVersion: identity.macOSVersion ?? "macOS",
                chipType: identity.chipType
            ),
            collectorService: collectorService,
            historyReader: collectorService.historyReader,
            processHistoryReader: collectorService.processHistoryReader,
            eventReader: collectorService.eventReader,
            insightsService: collectorService.insightsService
        )
        cloudSyncService.start()
        cloudSyncService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        refreshApprovedHosts()
    }

    var isCloudSyncRunning: Bool {
        cloudSyncService.isRunning
    }

    var cloudLastPublishedAt: Date? {
        cloudSyncService.lastPublishedAt
    }

    var cloudLastErrorMessage: String? {
        cloudSyncService.lastErrorMessage
    }

    // MARK: - Server Control

    func startServer() {
        server.start(collectorService: collectorService)
    }

    func stopServer() {
        server.stop()
    }

    func rotatePasscode() {
        server.rotatePasscode()
    }

    // MARK: - Auth Management

    func approveRequest(_ request: RemoteMonitoringServer.PendingAuthRequest, remember: Bool) {
        server.approveAuth(request, remember: remember)
        refreshApprovedHosts()
    }

    func denyRequest(_ request: RemoteMonitoringServer.PendingAuthRequest) {
        server.denyAuth(request)
    }

    func revokeHost(_ machineID: String) {
        RemoteAuthKeychain.revokeApproval(hostMachineID: machineID)
        server.disconnectHost(machineID)
        refreshApprovedHosts()
    }

    func refreshApprovedHosts() {
        approvedHosts = RemoteAuthKeychain.allApprovedHosts()
    }

    // MARK: - Machine Identity

    private static func buildLocalIdentity() -> RemoteMachineIdentity {
        let machineID = localMachineID()
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let modelID = modelIdentifier()

        return RemoteMachineIdentity(
            machineID: machineID,
            displayName: hostName,
            modelIdentifier: modelID,
            cpuName: cpuBrandString(),
            totalRAMGB: totalRAMGB(),
            macOSVersion: RemoteSystemDisplayFormatter.macOSDisplayString(version: ProcessInfo.processInfo.operatingSystemVersion),
            chipType: chipType()
        )
    }

    private static func localMachineID() -> String {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            return uuid
        }
        return RemoteMachineIDStore.persistentFallbackMachineID()
    }

    private static func modelIdentifier() -> String {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            if let data = model as? Data {
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "Mac"
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
        // Apple Silicon: read the chip name from IORegistry
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        if let chip = IORegistryEntryCreateCFProperty(service, "chip-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            return nil // chip-id is a number, not a name; skip for simplicity
        }
        // Fall back to sysctl
        var size = 0
        sysctlbyname("hw.targettype", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.targettype", &buf, &size, nil, 0)
        let target = String(cString: buf)
        return target.isEmpty ? nil : target
    }
}
