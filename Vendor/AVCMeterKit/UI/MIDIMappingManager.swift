import Foundation

/// Defines how a MIDI CC message maps to an engine parameter.
struct MIDIParameterMapping {
    let ccIndex: UInt8
    let targetParameter: String // e.g., "decay", "cutoff"
    let minValue: Float
    let maxValue: Float
}

/// Bridges MIDI CC events to engine parameter updates.
final class MIDIMappingManager {
    static let shared = MIDIMappingManager()

    // Maps (InstrumentID, ParameterName) -> Value
    private var parameterValues: [String: Float] = [:]
    private var mappings: [UInt8: MIDIParameterMapping] = [:]

    private init() {}

    func registerMapping(cc: UInt8, target: String, min: Float, max: Float) {
        mappings[cc] = MIDIParameterMapping(ccIndex: cc, targetParameter: target, minValue: min, maxValue: max)
    }

    func processCC(cc: UInt8, value: UInt8) -> (parameter: String, normalizedValue: Float)? {
        guard let mapping = mappings[cc] else { return nil }

        // Normalize 0-127 to min-max range
        let normalized = Float(value) / 127.0
        let mappedValue = mapping.minValue + (normalized * (mapping.maxValue - mapping.minValue))

        parameterValues[mapping.targetParameter] = mappedValue
        return (mapping.targetParameter, mappedValue)
    }

    func getValue(for parameter: String) -> Float {
        return parameterValues[parameter] ?? 0.0
    }
}
