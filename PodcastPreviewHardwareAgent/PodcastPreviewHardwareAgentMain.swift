import Foundation
import os.log
import Security
#if !HARDWARE_JOBBLESS_EMBEDS_CORE
import PodcastPreviewCore
#endif

final class HardwareMonitoringAgentServiceDelegate: NSObject, NSXPCListenerDelegate {
    #if HARDWARE_JOBBLESS_EMBEDS_CORE
    private static let loggingSubsystem = HardwareMonitoringServiceConstants.legacyHelperBundleID
    fileprivate static let listenerMachServiceName = HardwareMonitoringServiceConstants.legacyMachServiceName
    #else
    private static let loggingSubsystem = HardwareMonitoringServiceConstants.modernHelperBundleID
    fileprivate static let listenerMachServiceName = HardwareMonitoringServiceConstants.modernMachServiceName
    #endif

    private let logger = Logger(
        subsystem: HardwareMonitoringAgentServiceDelegate.loggingSubsystem,
        category: "Main"
    )
    private let allowedClientRequirement = XPCClientRequirement(
        teamID: "8CZML8FK2D",
        bundleIdentifiers: [
            HardwareMonitoringServiceConstants.mainAppBundleID
        ]
    )

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard allowedClientRequirement.accepts(newConnection) else {
            logger.error("Rejected hardware monitoring XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: HardwareMonitoringXPCProtocol.self)
        newConnection.exportedObject = HardwareMonitoringAgentDaemon.shared
        newConnection.resume()
        logger.log("Accepted hardware monitoring XPC connection")
        return true
    }
}

private struct XPCClientRequirement {
    private let requirement: SecRequirement

    init(teamID: String, bundleIdentifiers: [String]) {
        let identifierClauses = bundleIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        let requirementString = """
        anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and (\(identifierClauses))
        """

        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement)
        precondition(status == errSecSuccess && requirement != nil, "Invalid XPC client code requirement")
        self.requirement = requirement!
    }

    func accepts(_ connection: NSXPCConnection) -> Bool {
        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard copyStatus == errSecSuccess, let code else {
            return false
        }

        return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}

@main
struct PodcastPreviewHardwareAgentMain {
    static func main() {
        let delegate = HardwareMonitoringAgentServiceDelegate()
        let listener = NSXPCListener(machServiceName: HardwareMonitoringAgentServiceDelegate.listenerMachServiceName)
        listener.delegate = delegate
        listener.resume()
        HardwareMonitoringAgentDaemon.shared.bootstrapMonitoringOnLaunch()
        RunLoop.current.run()
    }
}
