import Foundation
import Compression

extension Data {
    /// Compresses the data using Zlib.
    public func compressed() -> Data? {
        let bufferSize = 65536
        var compressedData = Data()

        do {
            let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { outputBuffer.deallocate() }

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
            let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { outputBuffer.deallocate() }

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
