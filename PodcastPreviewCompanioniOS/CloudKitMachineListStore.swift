import PodcastPreviewShared
import CloudKit
import Foundation

struct CloudKitMachineListStore {
    private let database: CKDatabase

    init(database: CKDatabase) {
        self.database = database
    }

    func loadMachines() async throws -> [CompanionMachineIdentity] {
        let zoneIDs = try await fetchRecordZoneIDs(from: database)
            .filter { $0.zoneName.hasPrefix("\(CompanionCloudKitSchema.zonePrefix).") }

        let outcome = await withTaskGroup(of: Result<CompanionMachineIdentity?, Error>.self) { group in
            for zoneID in zoneIDs {
                group.addTask {
                    do {
                        return .success(try await loadMachine(in: zoneID))
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var machines: [CompanionMachineIdentity] = []
            var firstError: Error?
            for await identity in group {
                switch identity {
                case .success(let identity):
                    if let identity {
                        machines.append(identity)
                    }
                case .failure(let error):
                    if firstError == nil {
                        firstError = error
                    }
                }
            }
            return (machines, firstError)
        }

        let machines = outcome.0
        if machines.isEmpty, let error = outcome.1 {
            throw error
        }

        return machines.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func loadMachine(in zoneID: CKRecordZone.ID) async throws -> CompanionMachineIdentity? {
        let zonePrefix = "\(CompanionCloudKitSchema.zonePrefix)."
        guard zoneID.zoneName.hasPrefix(zonePrefix) else {
            return nil
        }

        let machineID = String(zoneID.zoneName.dropFirst(zonePrefix.count))
        let recordNames = [
            CompanionCloudKitSchema.machineIdentityRecordName(for: machineID),
            machineID
        ]

        for recordName in recordNames {
            let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
            do {
                let record = try await fetchRecord(recordID: recordID, from: database)
                guard record.recordType == CompanionCloudKitSchema.machineIdentityRecordType else {
                    continue
                }
                return CompanionMachineIdentity(record: record)
            } catch let error as CKError where error.code == .unknownItem {
                continue
            }
        }

        return nil
    }
}
