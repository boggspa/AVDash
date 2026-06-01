// File: PowerMetricsServiceMain.swift
// PodcastPreview Helper (daemon target)
// XPC daemon entry that publishes a Mach service defined by launchd.

import Foundation
import Security

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private static let allowedClientRequirement = XPCClientRequirement(
        teamID: "8CZML8FK2D",
        bundleIdentifiers: [
            "com.chrisizatt.PodcastPreview",
            "com.chrisizatt.PodcastPreview.HardwareAgent",
            "com.chrisizatt.PodcastPreview.HardwareJobBless"
        ]
    )

    private let daemon = PowerMetricsServiceDaemon()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.allowedClientRequirement.accepts(newConnection) else {
            NSLog(
                "Rejected PowerMetricsService XPC connection from pid %d",
                newConnection.processIdentifier
            )
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: PowerMetricsXPCProtocol.self)
        newConnection.exportedObject = daemon
        newConnection.resume()
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
struct PowerMetricsServiceMain {
    static func main() {
        let delegate = ServiceDelegate()
        let listener = NSXPCListener(machServiceName: PowerMetricsServiceConstants.activeMachServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
