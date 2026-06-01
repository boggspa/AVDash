import Foundation

enum HardwareMonitoringClientError: LocalizedError {
    case unavailable
    case registrationFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The hardware monitoring helper service requires macOS 11 or later."
        case .registrationFailed:
            return "The hardware monitoring helper service could not be registered."
        }
    }
}

enum HardwareMonitoringFeatureFlags {
    static let headlessAgentDefaultsKey = "hardwareMonitoringUsesHeadlessAgent"
    private static let headlessAgentEnvironmentKey = "PODCASTPREVIEW_HARDWARE_AGENT_ENABLED"

    static var usesHeadlessAgent: Bool {
        if let environmentOverride = environmentOverride {
            return environmentOverride
        }

        guard let storedValue = UserDefaults.standard.object(forKey: headlessAgentDefaultsKey) else {
            if #available(macOS 11.0, *) {
                return true
            }
            return false
        }

        if let boolValue = storedValue as? Bool {
            return boolValue
        }

        if let numberValue = storedValue as? NSNumber {
            return numberValue.boolValue
        }

        return false
    }

    static var prefersHeadlessAgentBackend: Bool {
        guard usesHeadlessAgent else { return false }
        if #available(macOS 11.0, *) {
            return true
        }
        return false
    }

    private static var environmentOverride: Bool? {
        parseBoolean(ProcessInfo.processInfo.environment[headlessAgentEnvironmentKey])
    }

    private static func parseBoolean(_ rawValue: String?) -> Bool? {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
