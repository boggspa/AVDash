#if os(macOS)
import CloudKit
import Foundation
import Combine
import PodcastPreviewShared

@MainActor
public final class CloudHardwareSyncService: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastPublishedAt: Date?
    @Published public private(set) var lastErrorMessage: String?

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let machineIdentity: RemoteMachineIdentity
    private let collectorService: HardwareCollectorService
    private let historyReader: HardwareHistoryReader
    private let processHistoryReader: ProcessHistoryReader
    private let eventReader: HardwareEventReader
    private let insightsService: HardwareInsightsService
    private var publishTask: Task<Void, Never>?

    public init(
        machineIdentity: RemoteMachineIdentity,
        collectorService: HardwareCollectorService,
        historyReader: HardwareHistoryReader,
        processHistoryReader: ProcessHistoryReader,
        eventReader: HardwareEventReader,
        insightsService: HardwareInsightsService,
        container: CKContainer = CKContainer(identifier: CompanionCloudKitSchema.containerIdentifier)
    ) {
        self.machineIdentity = machineIdentity
        self.collectorService = collectorService
        self.historyReader = historyReader
        self.processHistoryReader = processHistoryReader
        self.eventReader = eventReader
        self.insightsService = insightsService
        self.database = container.privateCloudDatabase
        self.zoneID = CompanionCloudKitSchema.zoneID(for: machineIdentity.machineID)
    }

    deinit {
        publishTask?.cancel()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lastErrorMessage = nil

        if collectorService.isHardwareStatsActive == false {
            collectorService.startHardwareStatsMonitoring()
        }

        publishTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrapZoneAndPublish()

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    if Task.isCancelled { break }
                    await self.publishCycle()
                } catch {
                    break
                }
            }
        }
    }

    public func stop() {
        publishTask?.cancel()
        publishTask = nil
        isRunning = false
    }

    public func publishNow() async {
        await bootstrapZoneAndPublish()
    }

    private func bootstrapZoneAndPublish() async {
        do {
            try await ensureZone()
            await publishCycle()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func ensureZone() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)
    }

    private func publishCycle() async {
        var currentSnapshotBytes: Int?
        var dashboardSnapshotBytes: Int?

        do {
            let builder = CloudHardwareDashboardBuilder(
                machineIdentity: machineIdentity,
                collectorService: collectorService,
                historyReader: historyReader,
                processHistoryReader: processHistoryReader,
                eventReader: eventReader,
                insightsService: insightsService
            )

            let minuteRollupPayload = await builder.makeMinuteTimelinePayload()
            let hourlyRollupPayload = await builder.makeHourlyTimelinePayload()
            let processRollupPayload = await builder.makeProcessRollupPayload()
            let hardwareEventPayload = await builder.makeHardwareEventPayload()
            let currentSnapshotPayload = builder.makeCurrentSnapshotPayload()

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            currentSnapshotBytes = try encoder.encode(currentSnapshotPayload).count

            let dashboardSnapshot = builder.makeDashboardSnapshotPayload(
                currentSnapshot: currentSnapshotPayload,
                minuteTimeline: minuteRollupPayload,
                hourlyTimeline: hourlyRollupPayload,
                processRollup: processRollupPayload,
                hardwareEvents: hardwareEventPayload
            )
            dashboardSnapshotBytes = try encoder.encode(dashboardSnapshot).count

            let recordsToSave: [(String, CKRecord)] = [
                ("Identity", try machineIdentity.makeCloudKitRecord(zoneID: zoneID)),
                ("Current Snapshot", try currentSnapshotPayload.makeCloudKitRecord(zoneID: zoneID)),
                ("Minute Rollup", try minuteRollupPayload.makeCloudKitRecord(recordType: CompanionCloudKitSchema.minuteRollupRecordType, zoneID: zoneID)),
                ("Hourly Rollup", try hourlyRollupPayload.makeCloudKitRecord(recordType: CompanionCloudKitSchema.hourlyRollupRecordType, zoneID: zoneID)),
                ("Process Rollup", try processRollupPayload.makeCloudKitRecord(zoneID: zoneID)),
                ("Hardware Events", try hardwareEventPayload.makeCloudKitRecord(zoneID: zoneID)),
                ("Dashboard", try dashboardSnapshot.makeCloudKitRecord(zoneID: zoneID))
            ]

            var saveErrors: [String] = []

            // Save critical records first
            for (name, record) in recordsToSave {
                let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
                operation.savePolicy = .allKeys
                operation.qualityOfService = .userInitiated

                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        operation.modifyRecordsCompletionBlock = { _, _, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                        database.add(operation)
                    }
                } catch {
                    let size = (record[CompanionCloudKitSchema.payloadDataField] as? Data)?.count
                        ?? (record[CompanionCloudKitSchema.snapshotDataField] as? Data)?.count
                        ?? 0
                    saveErrors.append("\(name) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))): \(error.localizedDescription)")
                }
            }

            lastPublishedAt = Date()

            if !saveErrors.isEmpty {
                lastErrorMessage = "Partial push: " + saveErrors.joined(separator: " · ")
            } else {
                lastErrorMessage = nil
            }
        } catch {
            let sizeSummary = [
                currentSnapshotBytes.map { "CurrentSnapshot \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" },
                dashboardSnapshotBytes.map { "Dashboard \(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))" }
            ]
            .compactMap { $0 }
            .joined(separator: " · ")

            lastErrorMessage = sizeSummary.isEmpty ? error.localizedDescription : "\(error.localizedDescription) (\(sizeSummary))"
        }
    }
}

#endif