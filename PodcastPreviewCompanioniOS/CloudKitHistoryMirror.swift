import PodcastPreviewShared
import CloudKit
import Foundation
import Combine

@MainActor
final class CloudKitHistoryMirror: ObservableObject {
    @Published private(set) var currentSnapshot: CompanionCurrentSnapshotPayload?
    @Published private(set) var minuteTimeline: CompanionTimelinePayload?
    @Published private(set) var hourlyTimeline: CompanionTimelinePayload?
    @Published private(set) var processRollup: CompanionProcessRollupPayload?
    @Published private(set) var hardwareEvents: CompanionHardwareEventPayload?

    private var activeMachineID: String?

    func reset() {
        activeMachineID = nil
        currentSnapshot = nil
        minuteTimeline = nil
        hourlyTimeline = nil
        processRollup = nil
        hardwareEvents = nil
    }

    func refresh(
        machineID: String,
        snapshotStore: CloudKitMachineSnapshotStore
    ) async throws {
        if activeMachineID != machineID {
            reset()
            activeMachineID = machineID
        }

        async let currentSnapshotTask = snapshotStore.loadCurrentSnapshot(machineID: machineID)
        async let minuteTimelineTask = snapshotStore.loadMinuteTimeline(machineID: machineID)
        async let hourlyTimelineTask = snapshotStore.loadHourlyTimeline(machineID: machineID)
        async let processRollupTask = snapshotStore.loadProcessRollup(machineID: machineID)
        async let hardwareEventsTask = snapshotStore.loadHardwareEvents(machineID: machineID)

        let loadedCurrentSnapshot = try await currentSnapshotTask
        currentSnapshot = loadedCurrentSnapshot
        minuteTimeline = try await minuteTimelineTask
        hourlyTimeline = try await hourlyTimelineTask
        processRollup = try await processRollupTask
        hardwareEvents = try await hardwareEventsTask
    }
}
