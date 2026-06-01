import Foundation
import CoreMIDI

/// Represents a MIDI device discovered on the system,
/// mirroring the structure of existing audio device models.
struct MIDIDeviceModel: Identifiable, Hashable {
    let id: MIDIUniqueID
    let name: String
    let manufacturer: String
    let model: String
    let isOnline: Bool
    let inputEndpoints: [MIDIEndpointRef]
    let outputEndpoints: [MIDIEndpointRef]

    // Conformance to Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MIDIDeviceModel, rhs: MIDIDeviceModel) -> Bool {
        lhs.id == rhs.id
    }
}
