import Foundation
import os.log
import Security

final class AudioRoutingAgentServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: AudioRoutingServiceConstants.helperBundleID, category: "Main")
    private let allowedClientRequirement = XPCClientRequirement(
        teamID: "8CZML8FK2D",
        bundleIdentifiers: [
            AudioRoutingServiceConstants.mainAppBundleID
        ]
    )

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard allowedClientRequirement.accepts(newConnection) else {
            logger.error("Rejected audio routing XPC connection from pid \(newConnection.processIdentifier, privacy: .public)")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: AudioRoutingXPCProtocol.self)
        newConnection.exportedObject = AudioRoutingAgentDaemon.shared
        newConnection.resume()
        logger.log("Accepted audio routing XPC connection")
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
struct PodcastPreviewAudioAgentMain {
    static func main() {
        let delegate = AudioRoutingAgentServiceDelegate()
        let listener = NSXPCListener(machServiceName: AudioRoutingServiceConstants.machServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
