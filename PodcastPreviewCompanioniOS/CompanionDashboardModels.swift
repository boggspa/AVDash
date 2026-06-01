import CloudKit
import SwiftUI
import Compression
import PodcastPreviewShared

// This file now primarily provides compatibility for the iOS companion app
// by type-aliasing or re-exporting from PodcastPreviewShared.
// Most logic has moved to PodcastPreviewShared for sharing with the main Mac app.

typealias CompanionMachineIdentity = RemoteMachineIdentity

extension Data {
    /// Compresses the data using Zlib.
    func compressed() -> Data? {
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
    func decompressed() -> Data? {
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
