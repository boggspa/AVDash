import Foundation
import Darwin
import os.log

struct LegacyUserLaunchAgentDescriptor {
    let plistName: String
    let label: String
    let helperExecutableName: String
}

enum LegacyUserLaunchAgentError: LocalizedError {
    case unavailable
    case missingEmbeddedPlist(String)
    case missingEmbeddedHelper(String)
    case invalidEmbeddedPlist(String)
    case launchctlFailed(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "User LaunchAgent registration is not available on this OS."
        case .missingEmbeddedPlist(let name):
            return "The bundled launch agent plist (\(name)) is missing from this app build."
        case .missingEmbeddedHelper(let name):
            return "The bundled helper executable (\(name)) is missing from this app build."
        case .invalidEmbeddedPlist(let name):
            return "The bundled launch agent plist (\(name)) could not be prepared for legacy installation."
        case .launchctlFailed(_, let message):
            return message
        }
    }
}

enum LegacyUserLaunchAgentSupport {
    private static let logger = Logger(subsystem: "com.chrisizatt.PodcastPreview", category: "LegacyUserLaunchAgent")

    static var isSupportedOS: Bool {
        if #available(macOS 13.0, *) {
            return false
        }
        if #available(macOS 11.0, *) {
            return true
        }
        return false
    }

    static var isSupportedOnCurrentOS: Bool {
        if #available(macOS 11.0, *) {
            return true
        }
        return false
    }

    static func bundledAssetsAvailable(for descriptor: LegacyUserLaunchAgentDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: bundledPlistURL(for: descriptor).path)
            && FileManager.default.fileExists(atPath: bundledHelperURL(for: descriptor).path)
    }

    static func isInstalled(for descriptor: LegacyUserLaunchAgentDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: installedPlistURL(for: descriptor).path)
            && FileManager.default.fileExists(atPath: bundledHelperURL(for: descriptor).path)
    }

    static func registerOrRefresh(
        _ descriptor: LegacyUserLaunchAgentDescriptor,
        allowOnModernOS: Bool = false
    ) throws {
        guard isSupportedOS || (allowOnModernOS && isSupportedOnCurrentOS) else {
            throw LegacyUserLaunchAgentError.unavailable
        }

        let bundledPlist = bundledPlistURL(for: descriptor)
        let helperURL = bundledHelperURL(for: descriptor)
        let installedPlist = installedPlistURL(for: descriptor)

        guard FileManager.default.fileExists(atPath: bundledPlist.path) else {
            throw LegacyUserLaunchAgentError.missingEmbeddedPlist(descriptor.plistName)
        }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw LegacyUserLaunchAgentError.missingEmbeddedHelper(descriptor.helperExecutableName)
        }

        try FileManager.default.createDirectory(
            at: installedPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try writePreparedPlist(from: bundledPlist, helperURL: helperURL, to: installedPlist)

        let domain = "gui/\(getuid())"
        let serviceIdentifier = "\(domain)/\(descriptor.label)"
        let plistPath = installedPlist.path

        _ = try? runLaunchctl(["bootout", serviceIdentifier], allowFailure: true)
        _ = try? runLaunchctl(["bootout", domain, plistPath], allowFailure: true)
        _ = try? runLaunchctl(["enable", serviceIdentifier], allowFailure: true)
        _ = try runLaunchctl(["bootstrap", domain, plistPath], allowFailure: false)
        _ = try? runLaunchctl(["kickstart", "-k", serviceIdentifier], allowFailure: true)

        logger.log("Legacy LaunchAgent installed for \(descriptor.label, privacy: .public)")
    }

    @discardableResult
    static func unregisterIfPresent(
        _ descriptor: LegacyUserLaunchAgentDescriptor,
        allowOnModernOS: Bool = false
    ) throws -> Bool {
        guard isSupportedOS || (allowOnModernOS && isSupportedOnCurrentOS) else {
            throw LegacyUserLaunchAgentError.unavailable
        }

        let installedPlist = installedPlistURL(for: descriptor)
        let domain = "gui/\(getuid())"
        let serviceIdentifier = "\(domain)/\(descriptor.label)"

        _ = try? runLaunchctl(["bootout", serviceIdentifier], allowFailure: true)
        _ = try? runLaunchctl(["bootout", domain, installedPlist.path], allowFailure: true)
        _ = try? runLaunchctl(["disable", serviceIdentifier], allowFailure: true)
        guard FileManager.default.fileExists(atPath: installedPlist.path) else {
            return false
        }

        try FileManager.default.removeItem(at: installedPlist)
        logger.log("Legacy LaunchAgent removed for \(descriptor.label, privacy: .public)")
        return true
    }

    private static func writePreparedPlist(from bundledPlist: URL, helperURL: URL, to installedPlist: URL) throws {
        let data = try Data(contentsOf: bundledPlist)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw LegacyUserLaunchAgentError.invalidEmbeddedPlist(bundledPlist.lastPathComponent)
        }

        plist.removeValue(forKey: "BundleProgram")
        plist["ProgramArguments"] = [helperURL.path]

        let installedData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try installedData.write(to: installedPlist, options: .atomic)
    }

    private static func runLaunchctl(_ arguments: [String], allowFailure: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard allowFailure || process.terminationStatus == 0 else {
            let command = (["/bin/launchctl"] + arguments).joined(separator: " ")
            throw LegacyUserLaunchAgentError.launchctlFailed(
                command: command,
                message: output.isEmpty ? "launchctl failed while registering the helper." : output
            )
        }

        return output
    }

    private static func bundledPlistURL(for descriptor: LegacyUserLaunchAgentDescriptor) -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent(descriptor.plistName)
    }

    private static func bundledHelperURL(for descriptor: LegacyUserLaunchAgentDescriptor) -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchServices")
            .appendingPathComponent(descriptor.helperExecutableName)
    }

    private static func installedPlistURL(for descriptor: LegacyUserLaunchAgentDescriptor) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent(descriptor.plistName)
    }
}
