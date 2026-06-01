#if os(macOS)
import Foundation
import Darwin
#if canImport(libproc)
import libproc
#else
// libproc symbols are available via Darwin on many SDKs; keep explicit import only if it compiles.
#endif

public enum PodcastPreviewProcessFamilyResolver {
    private static let bundleIdentifierPrefix = "com.chrisizatt.PodcastPreview"
    private static let executableNamePrefixes: [String] = [
        "PodcastPreview",
        "com.chrisizatt.PodcastPreview."
    ]

    public static func processIdentifiers(
        runningApplicationProvider: HardwareRunningApplicationProvider? = HeadlessRunningApplicationProvider.shared
    ) -> Set<Int32> {
        Set(
            listAllPIDs().filter { pid in
                matchesPodcastPreviewFamily(
                    pid: pid,
                    runningApplicationProvider: runningApplicationProvider
                )
            }
        )
    }

    public static func mainAppProcessIdentifier(
        runningApplicationProvider: HardwareRunningApplicationProvider? = HeadlessRunningApplicationProvider.shared
    ) -> Int32? {
        var bestMatch: (pid: Int32, launchDate: Date?)?

        for pid in listAllPIDs() {
            guard pid > 0 else { continue }

            let appInfo = runningApplicationProvider?.applicationInfo(for: pid)
            let bundleIdentifier = normalizedBundleIdentifier(appInfo?.bundleIdentifier)
            let executableName = executableName(for: pid)

            guard bundleIdentifier == normalizedBundleIdentifier(HardwareMonitoringServiceConstants.mainAppBundleID)
                || executableName == "PodcastPreview" else {
                continue
            }

            guard let existing = bestMatch else {
                bestMatch = (pid, appInfo?.launchDate)
                continue
            }

            let candidateLaunchDate = appInfo?.launchDate ?? .distantPast
            let existingLaunchDate = existing.launchDate ?? .distantPast
            if candidateLaunchDate > existingLaunchDate
                || (candidateLaunchDate == existingLaunchDate && pid > existing.pid) {
                bestMatch = (pid, appInfo?.launchDate)
            }
        }

        return bestMatch?.pid
    }

    private static func matchesPodcastPreviewFamily(
        pid: Int32,
        runningApplicationProvider: HardwareRunningApplicationProvider?
    ) -> Bool {
        guard pid > 0 else { return false }

        let bundleIdentifier = normalizedBundleIdentifier(
            runningApplicationProvider?.applicationInfo(for: pid)?.bundleIdentifier
        )
        if bundleIdentifier == normalizedBundleIdentifier(bundleIdentifierPrefix)
            || bundleIdentifier.hasPrefix(normalizedBundleIdentifier(bundleIdentifierPrefix) + ".") {
            return true
        }

        guard let executableName = executableName(for: pid)?.lowercased() else {
            return false
        }

        return executableNamePrefixes.contains { prefix in
            executableName.hasPrefix(prefix.lowercased())
        }
    }

    private static func executableName(for pid: Int32) -> String? {
        guard let executableURL = executableURL(for: pid) else { return nil }
        return executableURL.lastPathComponent
    }

    private static func executableURL(for pid: Int32) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuffer))
    }

    private static func listAllPIDs() -> [Int32] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }

        let count = Int(bytesNeeded) / MemoryLayout<pid_t>.stride
        var buffer = Array<pid_t>(repeating: 0, count: count)

        let bytesFilled = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, bytesNeeded)
        }
        guard bytesFilled > 0 else { return [] }

        let filledCount = Int(bytesFilled) / MemoryLayout<pid_t>.stride
        return Array(buffer[0..<filledCount]).map { Int32($0) }
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String {
        bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            ?? ""
    }
}

#endif