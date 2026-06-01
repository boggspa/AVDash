import Foundation

public enum HardwareCollectionSettings {
    public static let collectorIntervalDefaultsKey = "hardwareCollectorIntervalSeconds"
    public static let defaultCollectorIntervalSeconds = 1
    public static let graphWindowDefaultsKey = "graphWindowSeconds"
    public static let defaultGraphWindowSeconds = 1800
    public static let graphDisplayIntervalDefaultsKey = "hardwareGraphDisplayIntervalSeconds"
    public static let legacyGraphDisplayIntervalDefaultsKey = "sampleIntervalSeconds"
    public static let defaultGraphDisplayIntervalSeconds = 1
    public static let minimumLiveSeriesCapacity = 1800

    public static func collectorIntervalSeconds(userDefaults: UserDefaults = .standard) -> Int {
        let configuredInterval = userDefaults.integer(forKey: collectorIntervalDefaultsKey)
        return max(1, configuredInterval == 0 ? defaultCollectorIntervalSeconds : configuredInterval)
    }

    public static func graphDisplayIntervalSeconds(userDefaults: UserDefaults = .standard) -> Int {
        migrateLegacyGraphDisplayIntervalIfNeeded(userDefaults: userDefaults)
        let configuredInterval = userDefaults.integer(forKey: graphDisplayIntervalDefaultsKey)
        return max(1, configuredInterval == 0 ? defaultGraphDisplayIntervalSeconds : configuredInterval)
    }

    public static func graphWindowSeconds(userDefaults: UserDefaults = .standard) -> Int {
        let configuredWindow = userDefaults.integer(forKey: graphWindowDefaultsKey)
        return max(1, configuredWindow == 0 ? defaultGraphWindowSeconds : configuredWindow)
    }

    public static func liveSeriesCapacity(
        sampleIntervalSeconds: Int? = nil,
        userDefaults: UserDefaults = .standard
    ) -> Int {
        let resolvedSampleInterval = max(
            1,
            sampleIntervalSeconds ?? collectorIntervalSeconds(userDefaults: userDefaults)
        )
        let requestedWindowSeconds = graphWindowSeconds(userDefaults: userDefaults)
        let requestedSamples = Int(
            ceil(Double(requestedWindowSeconds) / Double(resolvedSampleInterval))
        ) + 1
        return max(minimumLiveSeriesCapacity, requestedSamples)
    }

    @discardableResult
    public static func migrateLegacyGraphDisplayIntervalIfNeeded(userDefaults: UserDefaults = .standard) -> Int {
        guard userDefaults.object(forKey: graphDisplayIntervalDefaultsKey) == nil else {
            let configuredInterval = userDefaults.integer(forKey: graphDisplayIntervalDefaultsKey)
            return max(1, configuredInterval == 0 ? defaultGraphDisplayIntervalSeconds : configuredInterval)
        }

        let legacyInterval = userDefaults.integer(forKey: legacyGraphDisplayIntervalDefaultsKey)
        let migratedInterval = max(1, legacyInterval == 0 ? defaultGraphDisplayIntervalSeconds : legacyInterval)
        userDefaults.set(migratedInterval, forKey: graphDisplayIntervalDefaultsKey)
        return migratedInterval
    }
}
