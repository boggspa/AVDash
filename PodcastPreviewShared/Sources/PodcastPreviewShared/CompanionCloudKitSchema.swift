import Foundation
import CloudKit
import Compression

extension Data {
    /// Compresses the data using Zlib.
    public func compressed() -> Data? {
        let bufferSize = 65536
        var compressedData = Data()

        do {
            let filter = try OutputFilter(.compress, using: .zlib) { (data: Data?) in
                if let data = data {
                    compressedData.append(data)
                }
            }

            var index = 0
            while index < self.count {
                let chunkCount = Swift.min(self.count - index, bufferSize)
                let subdata = self.subdata(in: index..<(index + chunkCount))
                try filter.write(subdata)
                index += chunkCount
            }

            try filter.finalize()
        } catch {
            return nil
        }

        return compressedData
    }

    /// Decompresses the data using Zlib.
    public func decompressed() -> Data? {
        let bufferSize = 65536
        var decompressedData = Data()

        do {
            let filter = try OutputFilter(.decompress, using: .zlib) { (data: Data?) in
                if let data = data {
                    decompressedData.append(data)
                }
            }

            var index = 0
            while index < self.count {
                let chunkCount = Swift.min(self.count - index, bufferSize)
                let subdata = self.subdata(in: index..<(index + chunkCount))
                try filter.write(subdata)
                index += chunkCount
            }

            try filter.finalize()
        } catch {
            return nil
        }

        return decompressedData
    }
}

public enum CompanionCloudKitSchema {
    public static let containerIdentifier = "iCloud.com.chrisizatt.PodcastPreview"
    public static let dashboardRecordType = "CompanionDashboardSnapshot"
    public static let machineIdentityRecordType = "CompanionMachineIdentity"
    public static let currentSnapshotRecordType = "CompanionCurrentSnapshot"
    public static let minuteRollupRecordType = "CompanionMinuteRollup"
    public static let hourlyRollupRecordType = "CompanionHourlyRollup"
    public static let processRollupRecordType = "CompanionProcessRollup"
    public static let hardwareEventRecordType = "CompanionHardwareEvent"
    public static let snapshotDataField = "snapshotData"
    public static let payloadDataField = "payloadData"
    public static let machineIDField = "machineID"
    public static let displayNameField = "displayName"
    public static let updatedAtField = "updatedAt"
    public static let isCompressedField = "isCompressed"
    public static let zonePrefix = "PodcastPreviewHardware"
    public static let identityRecordSuffix = "identity"
    public static let currentSnapshotRecordSuffix = "current-snapshot"
    public static let dashboardRecordSuffix = "dashboard"
    public static let minuteRollupRecordSuffix = "minute-rollup"
    public static let hourlyRollupRecordSuffix = "hourly-rollup"
    public static let processRollupRecordSuffix = "process"
    public static let hardwareEventRecordSuffix = "events"

    public static func zoneID(for machineID: String) -> CKRecordZone.ID {
        CKRecordZone.ID(
            zoneName: "\(zonePrefix).\(machineID.replacingOccurrences(of: " ", with: "-"))",
            ownerName: CKCurrentUserDefaultName
        )
    }

    public static func machineIdentityRecordName(for machineID: String) -> String {
        "\(machineID).\(identityRecordSuffix)"
    }

    public static func extractData(from record: CKRecord, field: String) -> Data? {
        guard let data = record[field] as? Data else { return nil }
        let isCompressedValue = (record[isCompressedField] as? NSNumber)?.int64Value ?? 0
        if isCompressedValue == 1 {
            return data.decompressed()
        }
        return data
    }

    public static func insertData(_ data: Data, into record: CKRecord, field: String) {
        if let compressed = data.compressed(), compressed.count < data.count {
            record[field] = compressed as CKRecordValue
            record[isCompressedField] = 1 as CKRecordValue
        } else {
            record[field] = data as CKRecordValue
            record[isCompressedField] = 0 as CKRecordValue
        }
    }

    public static func currentSnapshotRecordName(for machineID: String) -> String {
        "\(machineID).\(currentSnapshotRecordSuffix)"
    }

    public static func dashboardRecordName(for machineID: String) -> String {
        "\(machineID).\(dashboardRecordSuffix)"
    }

    public static func minuteRollupRecordName(for machineID: String) -> String {
        "\(machineID).\(minuteRollupRecordSuffix)"
    }

    public static func hourlyRollupRecordName(for machineID: String) -> String {
        "\(machineID).\(hourlyRollupRecordSuffix)"
    }

    public static func processRollupRecordName(for machineID: String) -> String {
        "\(machineID).\(processRollupRecordSuffix)"
    }

    public static func hardwareEventRecordName(for machineID: String) -> String {
        "\(machineID).\(hardwareEventRecordSuffix)"
    }
}
