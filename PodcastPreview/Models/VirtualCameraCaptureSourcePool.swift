import Foundation

@MainActor
final class VirtualCameraCaptureSourcePool {
    static let shared = VirtualCameraCaptureSourcePool()

    private struct Entry {
        var source: VirtualCameraCaptureSource
        var retainCount: Int
    }

    private var entries: [String: Entry] = [:]

    func acquire(uniqueID: String) -> VirtualCameraCaptureSource {
        if var entry = entries[uniqueID] {
            entry.retainCount += 1
            entries[uniqueID] = entry
            return entry.source
        }

        let source = VirtualCameraCaptureSource(uniqueID: uniqueID)
        entries[uniqueID] = Entry(source: source, retainCount: 1)
        return source
    }

    func release(uniqueID: String) {
        guard var entry = entries[uniqueID] else { return }
        entry.retainCount -= 1
        if entry.retainCount <= 0 {
            entry.source.stop()
            entries.removeValue(forKey: uniqueID)
        } else {
            entries[uniqueID] = entry
        }
    }
}
