import Foundation
import os.log

enum AudioRoutingDriverInstallError: LocalizedError {
    case missingEmbeddedDriver
    case authorizationCanceled
    case installFailed(String)
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingEmbeddedDriver:
            return "This build does not contain a FireWireNetBridge audio driver payload yet."
        case .authorizationCanceled:
            return "Audio driver install was canceled before admin authorization completed."
        case .installFailed(let message):
            return message.isEmpty
                ? "The audio driver install did not complete successfully."
                : message
        case .uninstallFailed(let message):
            return message.isEmpty
                ? "The audio driver uninstall did not complete successfully."
                : message
        }
    }
}

final class AudioRoutingDriverInstaller {
    private let logger = Logger(subsystem: AudioRoutingServiceConstants.mainAppBundleID, category: "AudioRoutingDriverInstaller")
    private let installQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.AudioRoutingDriverInstaller", qos: .userInitiated)

    func installIfNeeded(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sourceDriverURL = Self.bundledDriverURL() else {
            completion(.failure(AudioRoutingDriverInstallError.missingEmbeddedDriver))
            return
        }

        installQueue.async {
            let fileManager = FileManager.default
            let stagingRootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("PodcastPreviewFireWireInstall-\(UUID().uuidString)", isDirectory: true)
            let stagedDriverURL = stagingRootURL
                .appendingPathComponent(AudioRoutingServiceConstants.driverBundleName, isDirectory: true)

            do {
                try fileManager.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
                try fileManager.copyItem(at: sourceDriverURL, to: stagedDriverURL)
            } catch {
                self.logger.error("Failed to stage audio driver bundle: \(String(describing: error as NSError))")
                completion(.failure(AudioRoutingDriverInstallError.installFailed(error.localizedDescription)))
                return
            }

            defer {
                try? fileManager.removeItem(at: stagingRootURL)
            }

            let installCommand = """
            mkdir -p /Library/Audio/Plug-Ins/HAL && ditto \(Self.shellQuoted(stagedDriverURL.path)) \(Self.shellQuoted(AudioRoutingServiceConstants.installedDriverPath)) && ( /usr/bin/killall coreaudiod || /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod )
            """
            let appleScript = """
            do shell script "\(Self.appleScriptEscaped(installCommand))" with administrator privileges
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
                self.logger.error("Failed to launch audio driver installer: \(String(describing: error as NSError))")
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
                    completion(.failure(AudioRoutingDriverInstallError.authorizationCanceled))
                } else {
                    self.logger.error("Audio driver install failed: \(combinedOutput, privacy: .public)")
                    completion(.failure(AudioRoutingDriverInstallError.installFailed(combinedOutput)))
                }
                return
            }

            self.logger.log("Audio driver install command completed successfully")
            completion(.success(()))
        }
    }

    func uninstallIfPresent(completion: @escaping (Result<Void, Error>) -> Void) {
        installQueue.async {
            let uninstallCommand = """
            rm -rf \(Self.shellQuoted(AudioRoutingServiceConstants.installedDriverPath)) && ( /usr/bin/killall coreaudiod || /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod )
            """
            let appleScript = """
            do shell script "\(Self.appleScriptEscaped(uninstallCommand))" with administrator privileges
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
                self.logger.error("Failed to launch audio driver uninstaller: \(String(describing: error as NSError))")
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
                    completion(.failure(AudioRoutingDriverInstallError.authorizationCanceled))
                } else {
                    self.logger.error("Audio driver uninstall failed: \(combinedOutput, privacy: .public)")
                    completion(.failure(AudioRoutingDriverInstallError.uninstallFailed(combinedOutput)))
                }
                return
            }

            self.logger.log("Audio driver uninstall command completed successfully")
            completion(.success(()))
        }
    }

    static func bundledDriverURL(bundle: Bundle = .main) -> URL? {
        candidateDriverURLs(bundle: bundle).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func candidateDriverURLs(bundle: Bundle) -> [URL] {
        let bundleURL = bundle.bundleURL
        let buildProductsURL = bundleURL.deletingLastPathComponent()
        let workingDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        return [
            bundleURL.appendingPathComponent(AudioRoutingServiceConstants.bundledDriverRelativePath, isDirectory: true),
            buildProductsURL.appendingPathComponent(AudioRoutingServiceConstants.driverBundleName, isDirectory: true),
            bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(AudioRoutingServiceConstants.driverBundleName, isDirectory: true),
            workingDirectoryURL
                .appendingPathComponent(".firewirenetbridge-build", isDirectory: true)
                .appendingPathComponent(AudioRoutingServiceConstants.driverBundleName, isDirectory: true)
        ]
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
