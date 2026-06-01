import PodcastPreviewShared
import CloudKit
import Foundation

func perform(operation: CKQueryOperation, on database: CKDatabase) async throws {
    return try await withCheckedThrowingContinuation { continuation in
        operation.queryResultBlock = { result in
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
        database.add(operation)
    }
}

func fetchRecordZoneIDs(from database: CKDatabase) async throws -> [CKRecordZone.ID] {
    try await withCheckedThrowingContinuation { continuation in
        let lock = NSLock()
        var zoneIDs: [CKRecordZone.ID] = []
        let operation = CKFetchRecordZonesOperation.fetchAllRecordZonesOperation()
        operation.perRecordZoneResultBlock = { zoneID, result in
            if case .success = result {
                lock.lock()
                zoneIDs.append(zoneID)
                lock.unlock()
            }
        }
        operation.fetchRecordZonesResultBlock = { result in
            switch result {
            case .success:
                continuation.resume(returning: zoneIDs)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
        database.add(operation)
    }
}

func fetchRecord(recordID: CKRecord.ID, from database: CKDatabase) async throws -> CKRecord {
    return try await withCheckedThrowingContinuation { continuation in
        let lock = NSLock()
        var didResume = false

        func resume(_ result: Result<CKRecord, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            continuation.resume(with: result)
        }

        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        operation.perRecordResultBlock = { _, result in
            switch result {
            case .success(let record):
                resume(.success(record))
            case .failure(let error):
                resume(.failure(error))
            }
        }
        operation.fetchRecordsResultBlock = { result in
            if case .failure(let error) = result {
                resume(.failure(error))
            }
        }
        database.add(operation)
    }
}
