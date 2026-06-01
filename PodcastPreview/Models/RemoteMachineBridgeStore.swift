import Foundation
import PodcastPreviewCore

@MainActor
final class RemoteMachineBridgeStore {
    static let shared = RemoteMachineBridgeStore()

    private var bridges: [String: RemoteMachineHardwareBridge] = [:]

    private init() {}

    func bridge(for connection: RemoteMachineConnection) -> RemoteMachineHardwareBridge {
        if let existing = bridges[connection.id], existing.isBound(to: connection) {
            return existing
        }

        let bridge = RemoteMachineHardwareBridge(connection: connection)
        bridges[connection.id] = bridge
        return bridge
    }
}
