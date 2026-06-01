import Foundation

public struct HardwareRunningApplicationInfo {
    public let localizedName: String?
    public let bundleIdentifier: String?
    public let launchDate: Date?

    public init(
        localizedName: String? = nil,
        bundleIdentifier: String? = nil,
        launchDate: Date? = nil
    ) {
        self.localizedName = localizedName
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }
}

public protocol HardwareRunningApplicationProvider {
    func applicationInfo(for pid: Int32) -> HardwareRunningApplicationInfo?
}

#if os(macOS)
#if canImport(libproc)
import libproc
#endif

public final class HeadlessRunningApplicationProvider: HardwareRunningApplicationProvider, @unchecked Sendable {
    public static let shared = HeadlessRunningApplicationProvider()

    private struct BundleIdentity: Sendable {
        let localizedName: String?
        let bundleIdentifier: String?
    }

    private let lock = NSLock()
    private var bundleIdentityCache: [String: BundleIdentity] = [:]

    public init() {}

    public func applicationInfo(for pid: Int32) -> HardwareRunningApplicationInfo? {
        guard pid > 0,
              let executableURL = Self.executableURL(for: pid) else {
            return nil
        }

        let bundleIdentity = cachedBundleIdentity(for: executableURL)
        let fallbackName = executableURL.lastPathComponent

        return HardwareRunningApplicationInfo(
            localizedName: bundleIdentity.localizedName ?? fallbackName,
            bundleIdentifier: bundleIdentity.bundleIdentifier,
            launchDate: Self.launchDate(for: pid)
        )
    }

    public func processIdentifier(matchingBundleIdentifier bundleIdentifier: String) -> Int32? {
        let normalizedBundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier)
        guard !normalizedBundleIdentifier.isEmpty else { return nil }

        var bestMatch: (pid: Int32, launchDate: Date?)?

        for pid in Self.listAllPIDs() where pid > 0 {
            guard let info = applicationInfo(for: pid),
                  Self.normalizedBundleIdentifier(info.bundleIdentifier) == normalizedBundleIdentifier else {
                continue
            }

            guard let existing = bestMatch else {
                bestMatch = (pid, info.launchDate)
                continue
            }

            let candidateLaunchDate = info.launchDate ?? .distantPast
            let existingLaunchDate = existing.launchDate ?? .distantPast
            if candidateLaunchDate > existingLaunchDate
                || (candidateLaunchDate == existingLaunchDate && pid > existing.pid) {
                bestMatch = (pid, info.launchDate)
            }
        }

        return bestMatch?.pid
    }

    private func cachedBundleIdentity(for executableURL: URL) -> BundleIdentity {
        let cacheKey = Self.bundleCacheKey(for: executableURL)
        lock.lock()
        if let cached = bundleIdentityCache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Self.resolveBundleIdentity(for: executableURL)

        lock.lock()
        bundleIdentityCache[cacheKey] = resolved
        lock.unlock()

        return resolved
    }

    private static func bundleCacheKey(for executableURL: URL) -> String {
        bundleURL(containing: executableURL)?.path ?? executableURL.path
    }

    private static func resolveBundleIdentity(for executableURL: URL) -> BundleIdentity {
        guard let bundleURL = bundleURL(containing: executableURL),
              let bundle = Bundle(url: bundleURL) else {
            return BundleIdentity(localizedName: nil, bundleIdentifier: nil)
        }

        let localizedName =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? executableURL.deletingPathExtension().lastPathComponent

        return BundleIdentity(
            localizedName: localizedName,
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    private static func bundleURL(containing executableURL: URL) -> URL? {
        var currentURL = executableURL.deletingLastPathComponent()
        while currentURL.path != "/" && !currentURL.path.isEmpty {
            if currentURL.pathExtension == "app" {
                return currentURL
            }
            currentURL.deleteLastPathComponent()
        }
        return nil
    }

    private static func executableURL(for pid: Int32) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuffer))
    }

    private static func launchDate(for pid: Int32) -> Date? {
        var bsdInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, infoSize)
        guard result == infoSize else { return nil }

        let seconds = TimeInterval(bsdInfo.pbi_start_tvsec)
        let microseconds = TimeInterval(bsdInfo.pbi_start_tvusec) / 1_000_000.0
        return Date(timeIntervalSince1970: seconds + microseconds)
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

public enum HardwareTrackedProcessResolver {
    public static func mainAppProcessIdentifier() -> Int32? {
        PodcastPreviewProcessFamilyResolver.mainAppProcessIdentifier()
    }
}
#endif
