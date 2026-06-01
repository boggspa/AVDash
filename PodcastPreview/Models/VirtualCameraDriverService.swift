
import Foundation
import CoreMediaIO
import AVFoundation
import Combine
import PodcastPreviewCore

/// Skeleton service for managing the Virtual Camera System Extension (CMIOExtension)
enum VirtualCameraDriverInstallError: LocalizedError {
    case missingEmbeddedDriver
    case authorizationCanceled
    case installFailed(String)
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingEmbeddedDriver:
            return "This build does not contain a bundled virtual camera DAL payload yet."
        case .authorizationCanceled:
            return "Virtual camera driver installation was canceled before admin authorization completed."
        case .installFailed(let message):
            return message.isEmpty
                ? "The virtual camera driver install did not complete successfully."
                : message
        case .uninstallFailed(let message):
            return message.isEmpty
                ? "The virtual camera driver uninstall did not complete successfully."
                : message
        }
    }
}

final class VirtualCameraDriverService: ObservableObject {
    static let shared = VirtualCameraDriverService()

    private let extensionBundleIdentifier = "com.chrisizatt.PodcastPreview.CameraExtension"
    private let installQueue = DispatchQueue(
        label: "com.chrisizatt.PodcastPreview.VirtualCameraDriverService",
        qos: .userInitiated
    )

    @Published private(set) var isInstalled: Bool = false
    @Published private(set) var isBundledPayloadAvailable: Bool = false
    @Published private(set) var actionInProgress: Bool = false
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var driverBundleName: String = "PodcastPreview Virtual Camera"

    private init() {
        refreshStatus()
    }

    func refreshStatus() {
        let bundledURL = Self.bundledDriverURL()
        let installedURL = Self.installedDriverURL()
        let bundleName = installedURL?.deletingPathExtension().lastPathComponent
            ?? bundledURL?.deletingPathExtension().lastPathComponent
            ?? "PodcastPreview Virtual Camera"
        let message: String

        if let installedURL {
            message = "\(bundleName) is installed in \(installedURL.deletingLastPathComponent().path)."
        } else if bundledURL != nil {
            message = "\(bundleName) is bundled with this build and ready to install."
        } else {
            message = "This build does not contain a bundled virtual camera DAL payload yet."
        }

        DispatchQueue.main.async {
            self.isInstalled = installedURL != nil
            self.isBundledPayloadAvailable = bundledURL != nil
            self.driverBundleName = bundleName
            if !self.actionInProgress {
                self.statusMessage = message
            }
        }
    }

    func installDriver() {
        guard !actionInProgress else { return }
        guard let sourceDriverURL = Self.bundledDriverURL() else {
            DispatchQueue.main.async {
                self.isBundledPayloadAvailable = false
                self.statusMessage = VirtualCameraDriverInstallError.missingEmbeddedDriver.localizedDescription
            }
            return
        }

        AppDebugConsole.log("Virtual camera driver installation requested for \(extensionBundleIdentifier)", category: "Video")

        DispatchQueue.main.async {
            self.actionInProgress = true
            self.statusMessage = ""
        }

        installQueue.async {
            let fileManager = FileManager.default
            let stagingRootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("PodcastPreviewVirtualCameraInstall-\(UUID().uuidString)", isDirectory: true)
            let stagedDriverURL = stagingRootURL
                .appendingPathComponent(sourceDriverURL.lastPathComponent, isDirectory: true)
            let installedDriverURL = Self.installedDriverRootURL()
                .appendingPathComponent(sourceDriverURL.lastPathComponent, isDirectory: true)

            do {
                try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceDriverURL, to: stagedDriverURL)
            } catch {
                self.finishAction(
                    result: .failure(VirtualCameraDriverInstallError.installFailed(error.localizedDescription)),
                    successMessage: nil
                )
                return
            }

            defer {
                try? fileManager.removeItem(at: stagingRootURL)
            }

            let installCommand = """
            mkdir -p /Library/CoreMediaIO/Plug-Ins/DAL && rm -rf \(Self.shellQuoted(installedDriverURL.path)) && ditto \(Self.shellQuoted(stagedDriverURL.path)) \(Self.shellQuoted(installedDriverURL.path)) && ( sudo killall VDCAssistant || true ) && ( sudo killall AppleCameraAssistant || true ) && ( sudo killall Assistant || true ) && ( sudo killall CameraAssistant || true ) && ( sudo killall -9 VDCAssistant || true )
            """

            self.runPrivileged(command: installCommand) { result in
                let normalizedResult: Result<Void, Error>
                switch result {
                case .success:
                    normalizedResult = .success(())
                case .failure(let error):
                    if let installError = error as? VirtualCameraDriverInstallError {
                        normalizedResult = .failure(installError)
                    } else {
                        normalizedResult = .failure(VirtualCameraDriverInstallError.installFailed(error.localizedDescription))
                    }
                }

                self.finishAction(
                    result: normalizedResult,
                    successMessage: "\(sourceDriverURL.deletingPathExtension().lastPathComponent) was installed and camera services were refreshed."
                )
            }
        }
    }

    func uninstallDriver() {
        guard !actionInProgress else { return }
        guard let installedURL = Self.installedDriverURL() else {
            DispatchQueue.main.async {
                self.isInstalled = false
                self.statusMessage = "No installed virtual camera DAL bundle was found."
            }
            return
        }

        AppDebugConsole.log("Virtual camera driver uninstall requested for \(extensionBundleIdentifier)", category: "Video")

        DispatchQueue.main.async {
            self.actionInProgress = true
            self.statusMessage = ""
        }

        let uninstallCommand = """
        rm -rf \(Self.shellQuoted(installedURL.path)) && ( /usr/bin/killall VDCAssistant || true ) && ( /usr/bin/killall AppleCameraAssistant || true )
        """

        installQueue.async {
            self.runPrivileged(command: uninstallCommand) { result in
                let normalizedResult: Result<Void, Error>
                switch result {
                case .success:
                    normalizedResult = .success(())
                case .failure(let error):
                    if let installError = error as? VirtualCameraDriverInstallError {
                        switch installError {
                        case .authorizationCanceled:
                            normalizedResult = .failure(installError)
                        case .installFailed(let message):
                            normalizedResult = .failure(VirtualCameraDriverInstallError.uninstallFailed(message))
                        case .missingEmbeddedDriver:
                            normalizedResult = .failure(VirtualCameraDriverInstallError.uninstallFailed(installError.localizedDescription))
                        case .uninstallFailed:
                            normalizedResult = .failure(installError)
                        }
                    } else {
                        normalizedResult = .failure(VirtualCameraDriverInstallError.uninstallFailed(error.localizedDescription))
                    }
                }

                self.finishAction(
                    result: normalizedResult,
                    successMessage: "\(installedURL.deletingPathExtension().lastPathComponent) was uninstalled and camera services were refreshed."
                )
            }
        }
    }

    /// Feeds a processed frame to the Virtual Camera stream
    func pushFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        // This would use CMIOExtensionStream.send(_:presentationTimeStamp:)
        // to broadcast the frame to any app using the virtual camera.
    }

    static func bundledDriverURL(bundle: Bundle = .main) -> URL? {
        candidateDriverURLs(bundle: bundle).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func installedDriverURL() -> URL? {
        let rootURL = installedDriverRootURL()
        let fileManager = FileManager.default

        if let bundledName = bundledDriverURL()?.lastPathComponent {
            let bundledMatch = rootURL.appendingPathComponent(bundledName, isDirectory: true)
            if fileManager.fileExists(atPath: bundledMatch.path) {
                return bundledMatch
            }
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return contents.first { isPotentialDriverBundleName($0.lastPathComponent) }
    }

    private static func installedDriverRootURL() -> URL {
        URL(fileURLWithPath: "/Library/CoreMediaIO/Plug-Ins/DAL", isDirectory: true)
    }

    private static func candidateDriverURLs(bundle: Bundle) -> [URL] {
        let fileManager = FileManager.default
        let bundleURL = bundle.bundleURL
        let buildProductsURL = bundleURL.deletingLastPathComponent()
        let workingDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let searchDirectories = [
            bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("CoreMediaIO", isDirectory: true)
                .appendingPathComponent("Plug-Ins", isDirectory: true)
                .appendingPathComponent("DAL", isDirectory: true),
            buildProductsURL,
            bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true),
            workingDirectoryURL
                .appendingPathComponent(".virtualcamera-build", isDirectory: true)
        ]

        var candidates: [URL] = []
        for directory in searchDirectories {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            candidates.append(contentsOf: contents.filter { isPotentialDriverBundleName($0.lastPathComponent) })
        }

        return candidates
    }

    private static func isPotentialDriverBundleName(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        guard lowercased.hasSuffix(".driver") || lowercased.hasSuffix(".plugin") else { return false }
        return lowercased.contains("virtualcamera")
            || (lowercased.contains("virtual") && lowercased.contains("camera"))
            || lowercased.contains("cameraextension")
    }

    private func runPrivileged(command: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let appleScript = """
        do shell script "\(Self.appleScriptEscaped(command))" with administrator privileges
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            completion(.failure(error))
            return
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combinedOutput = [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        guard process.terminationStatus == 0 else {
            if combinedOutput.localizedCaseInsensitiveContains("User canceled") {
                completion(.failure(VirtualCameraDriverInstallError.authorizationCanceled))
            } else {
                completion(.failure(VirtualCameraDriverInstallError.installFailed(combinedOutput)))
            }
            return
        }

        completion(.success(()))
    }

    private func finishAction(
        result: Result<Void, Error>,
        successMessage: String?
    ) {
        let resolvedMessage: String
        switch result {
        case .success:
            resolvedMessage = successMessage ?? "Virtual camera driver action completed."
        case .failure(let error):
            resolvedMessage = error.localizedDescription
        }

        DispatchQueue.main.async {
            self.actionInProgress = false
            self.statusMessage = resolvedMessage
            self.isBundledPayloadAvailable = Self.bundledDriverURL() != nil
            self.isInstalled = Self.installedDriverURL() != nil
            if let installedURL = Self.installedDriverURL() {
                self.driverBundleName = installedURL.deletingPathExtension().lastPathComponent
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.refreshStatus()
            DispatchQueue.main.async {
                self.statusMessage = resolvedMessage
            }
        }

        AppDebugConsole.log(resolvedMessage, category: "Video")
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Extension Boilerplate (Reference)
/*
class PodcastPreviewCameraExtension: NSObject, CMIOExtensionProviderSource {
    // 1. Create a provider
    // 2. Define a device with name "PodcastPreview Virtual Camera"
    // 3. Define a stream with supported formats (e.g. 1920x1080 @ 30fps)
    // 4. Handle client connections
    // 5. Provide frames from the ComposerModel
}
*/
