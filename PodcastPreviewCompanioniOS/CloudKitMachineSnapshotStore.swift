import PodcastPreviewShared
import CloudKit
import Foundation

struct CloudKitMachineSnapshotStore {
    private let database: CKDatabase

    init(database: CKDatabase) {
        self.database = database
    }

    func loadDashboards(machineIDs: [String]) async throws -> [CompanionDashboardSnapshot] {
        let outcome = await withTaskGroup(of: Result<CompanionDashboardSnapshot?, Error>.self) { group in
            for machineID in machineIDs {
                group.addTask {
                    do {
                        return .success(try await loadDashboard(machineID: machineID))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var dashboards: [CompanionDashboardSnapshot] = []
            var firstError: Error?
            for await dashboard in group {
                switch dashboard {
                case .success(let dashboard):
                    if let dashboard {
                        dashboards.append(dashboard)
                    }
                case .failure(let error):
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            return (dashboards, firstError)
        }

        let dashboards = outcome.0
        if dashboards.isEmpty, let error = outcome.1 {
            throw error
        }

        return dashboards.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadCurrentSnapshotPayloads(machineIDs: [String]) async throws -> [CompanionCurrentSnapshotPayload] {
        let outcome = await withTaskGroup(of: Result<CompanionCurrentSnapshotPayload?, Error>.self) { group in
            for machineID in machineIDs {
                group.addTask {
                    do {
                        return .success(try await loadCurrentSnapshot(machineID: machineID))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var payloads: [CompanionCurrentSnapshotPayload] = []
            var firstError: Error?
            for await payload in group {
                switch payload {
                case .success(let payload):
                    if let payload {
                        payloads.append(payload)
                    }
                case .failure(let error):
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            return (payloads, firstError)
        }

        let payloads = outcome.0
        if payloads.isEmpty, let error = outcome.1 {
            throw error
        }

        return payloads
    }

    func loadCurrentSnapshot(machineID: String) async throws -> CompanionCurrentSnapshotPayload? {
        try await fetchPayload(
            recordType: CompanionCloudKitSchema.currentSnapshotRecordType,
            recordName: CompanionCloudKitSchema.currentSnapshotRecordName(for: machineID),
            machineID: machineID,
            decode: CompanionCurrentSnapshotPayload.init(record:)
        )
    }

    func loadDashboard(machineID: String) async throws -> CompanionDashboardSnapshot? {
        try await fetchPayload(
            recordType: CompanionCloudKitSchema.dashboardRecordType,
            recordName: CompanionCloudKitSchema.dashboardRecordName(for: machineID),
            machineID: machineID,
            decode: CompanionDashboardSnapshot.init(record:)
        )
    }

    func loadMinuteTimeline(machineID: String) async throws -> CompanionTimelinePayload? {
        try await fetchPayload(
            recordType: CompanionCloudKitSchema.minuteRollupRecordType,
            recordName: CompanionCloudKitSchema.minuteRollupRecordName(for: machineID),
            machineID: machineID,
            decode: CompanionTimelinePayload.init(record:)
        )
    }

    func loadHourlyTimeline(machineID: String) async throws -> CompanionTimelinePayload? {
        try await fetchPayload(
            recordType: CompanionCloudKitSchema.hourlyRollupRecordType,
            recordName: CompanionCloudKitSchema.hourlyRollupRecordName(for: machineID),
            machineID: machineID,
            decode: CompanionTimelinePayload.init(record:)
        )
    }

    func loadProcessRollup(machineID: String) async throws -> CompanionProcessRollupPayload? {
        try await fetchPayload(
            recordType: CompanionCloudKitSchema.processRollupRecordType,
            recordName: CompanionCloudKitSchema.processRollupRecordName(for: machineID),
            machineID: machineID,
            decode: CompanionProcessRollupPayload.init(record:)
        )
    }

    func loadHardwareEvents(machineID: String) async throws -> CompanionHardwareEventPayload? {
        try await fetchPayload(
            recordType: CompanionCloudKitSchema.hardwareEventRecordType,
            recordName: CompanionCloudKitSchema.hardwareEventRecordName(for: machineID),
            machineID: machineID,
            decode: CompanionHardwareEventPayload.init(record:)
        )
    }

    private func fetchPayload<Payload>(
        recordType: String,
        recordName: String,
        machineID: String,
        decode: (CKRecord) -> Payload?
    ) async throws -> Payload? {
        let recordID = CKRecord.ID(
            recordName: recordName,
            zoneID: CompanionCloudKitSchema.zoneID(for: machineID)
        )

        do {
            let record = try await fetchRecord(recordID: recordID, from: database)
            guard record.recordType == recordType else { return nil }
            return decode(record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
