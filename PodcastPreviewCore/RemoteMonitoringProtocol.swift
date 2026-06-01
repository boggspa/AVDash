//
//  RemoteMonitoringProtocol.swift
//  PodcastPreviewCore
//
//  Network protocol models for remote hardware monitoring.
//  Defines the message types exchanged between host and companion machines.
//

import Foundation
import PodcastPreviewShared

// MARK: - Service Identity

public enum RemoteMonitoringConstants {
    public static let bonjourServiceType = "_ppremotehw._tcp"
    public static let bonjourServiceDomain = "local."
    public static let protocolVersion: UInt16 = 1
    /// TXT record key for the machine's model identifier (e.g. "MacBookPro18,1").
    public static let txtKeyModel = "model"
    /// TXT record key for the companion protocol version.
    public static let txtKeyVersion = "ver"
    /// TXT record key for the machine's display name.
    public static let txtKeyHostname = "hostname"
}

// MARK: - Wire Envelope

/// Every message on the wire is prefixed with a 4-byte big-endian length
/// followed by a JSON-encoded `RemoteMonitoringEnvelope`.
public struct RemoteMonitoringEnvelope: Codable, Sendable {
    public let version: UInt16
    public let kind: RemoteMonitoringMessageKind
    public let payload: Data?

    public init(kind: RemoteMonitoringMessageKind, payload: Data? = nil) {
        self.version = RemoteMonitoringConstants.protocolVersion
        self.kind = kind
        self.payload = payload
    }
}

public enum RemoteMonitoringMessageKind: String, Codable, Sendable {
    // Host → Companion
    case authRequest
    case startStreaming
    case stopStreaming
    case ping

    // Companion → Host
    case authChallenge
    case authResult
    case telemetryFrame
    case pollingSnapshot
    case machineIdentity
    case pong
    case error
}

// MARK: - Auth Messages

public struct RemoteAuthChallenge: Codable, Sendable {
    public let machineID: String
    public let machineName: String
    public let machineModel: String
    public let nonce: String

    public init(machineID: String, machineName: String, machineModel: String) {
        self.machineID = machineID
        self.machineName = machineName
        self.machineModel = machineModel
        self.nonce = UUID().uuidString
    }
}

public struct RemoteAuthRequest: Codable, Sendable {
    public let hostMachineID: String
    public let hostName: String
    public let nonce: String
    public let passcode: String

    public init(hostMachineID: String, hostName: String, nonce: String, passcode: String) {
        self.hostMachineID = hostMachineID
        self.hostName = hostName
        self.nonce = nonce
        self.passcode = passcode
    }
}

public struct RemoteAuthResult: Codable, Sendable {
    public let accepted: Bool
    public let reason: String?
    /// An opaque session token the host can use for reconnection.
    public let sessionToken: String?

    public init(accepted: Bool, reason: String? = nil, sessionToken: String? = nil) {
        self.accepted = accepted
        self.reason = reason
        self.sessionToken = sessionToken
    }
}



// MARK: - Streaming Payload

/// A lightweight telemetry payload sent periodically from companion to host.
/// Mirrors `HardwareTelemetryFrame` but adds machine context for the remote case.
public struct RemoteTelemetryPayload: Codable, Sendable {
    public let machineID: String
    public let frame: HardwareTelemetryFrame

    public init(machineID: String, frame: HardwareTelemetryFrame) {
        self.machineID = machineID
        self.frame = frame
    }
}

/// A richer snapshot sent at lower frequency to populate sidebar cards.
public struct RemotePollingPayload: Codable, Sendable {
    public let machineID: String
    public let snapshot: HardwareCollectorPollingSnapshot

    public init(machineID: String, snapshot: HardwareCollectorPollingSnapshot) {
        self.machineID = machineID
        self.snapshot = snapshot
    }
}

// MARK: - Error

public struct RemoteMonitoringError: Codable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Passcode Generation

public enum RemotePasscodeGenerator {
    public static let length = 6

    /// Generates a random 6-digit numeric passcode displayed on the companion Mac.
    /// Short codes are fine here because TLS-PSK limits brute-force to a single
    /// LAN TCP handshake attempt per try.
    public static func generate() -> String {
        let digits = (0..<length).map { _ in Int.random(in: 0...9) }
        return digits.map(String.init).joined()
    }

    /// Normalizes user-entered passcodes by stripping display separators and any
    /// other non-digit characters from the 6-digit code.
    public static func normalized(_ passcode: String) -> String {
        String(passcode.unicodeScalars.filter(CharacterSet.decimalDigits.contains))
    }

    /// Formats a passcode for display: "123 456"
    public static func formatted(_ passcode: String) -> String {
        let normalizedPasscode = normalized(passcode)
        guard normalizedPasscode.count == length else { return normalizedPasscode }
        let idx = normalizedPasscode.index(normalizedPasscode.startIndex, offsetBy: 3)
        return "\(normalizedPasscode[..<idx]) \(normalizedPasscode[idx...])"
    }
}

// MARK: - Display Formatting

public enum RemoteSystemDisplayFormatter {
    public static func macOSDisplayString(version: OperatingSystemVersion) -> String {
        let name = macOSName(forMajorVersion: version.majorVersion)
        return "macOS \(name) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static func macOSDisplayString(from rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("macOS ") {
            return trimmed
        }

        let versionComponents = parseVersionComponents(from: trimmed)
        guard let major = versionComponents.first else {
            return trimmed
        }

        let minor = versionComponents.count > 1 ? versionComponents[1] : 0
        let patch = versionComponents.count > 2 ? versionComponents[2] : 0
        let name = macOSName(forMajorVersion: major)
        return "macOS \(name) \(major).\(minor).\(patch)"
    }

    private static func parseVersionComponents(from rawValue: String) -> [Int] {
        rawValue
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }

    private static func macOSName(forMajorVersion majorVersion: Int) -> String {
        switch majorVersion {
        case 11: return "Big Sur"
        case 12: return "Monterey"
        case 13: return "Ventura"
        case 14: return "Sonoma"
        case 15: return "Sequoia"
        case 26: return "Tahoe"
        default: return "macOS"
        }
    }
}

public enum RemoteMachineIDStore {
    private static let fallbackMachineIDDefaultsKey = "PodcastPreview.RemoteMonitoring.FallbackMachineID"

    public static func persistentFallbackMachineID() -> String {
        if let existing = UserDefaults.standard.string(forKey: fallbackMachineIDDefaultsKey),
           !existing.isEmpty {
            return existing
        }

        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: fallbackMachineIDDefaultsKey)
        return generated
    }
}

// MARK: - Wire Encoding Helpers

public enum RemoteMonitoringWire {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    /// Encode a message into a length-prefixed data blob ready for the wire.
    public static func encode(_ envelope: RemoteMonitoringEnvelope) throws -> Data {
        let body = try encoder.encode(envelope)
        var length = UInt32(body.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(body)
        return out
    }

    /// Encode a typed payload into an envelope.
    public static func envelope<T: Encodable>(kind: RemoteMonitoringMessageKind, payload: T) throws -> RemoteMonitoringEnvelope {
        let payloadData = try encoder.encode(payload)
        return RemoteMonitoringEnvelope(kind: kind, payload: payloadData)
    }

    /// Decode a payload from an envelope.
    public static func decodePayload<T: Decodable>(_ type: T.Type, from envelope: RemoteMonitoringEnvelope) throws -> T {
        guard let data = envelope.payload else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing payload"))
        }
        return try decoder.decode(type, from: data)
    }

    /// Decode an envelope from raw data (without the 4-byte length prefix).
    public static func decodeEnvelope(from data: Data) throws -> RemoteMonitoringEnvelope {
        return try decoder.decode(RemoteMonitoringEnvelope.self, from: data)
    }

    /// Read a 4-byte big-endian length prefix.
    public static func readLength(from data: Data) -> UInt32? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}
