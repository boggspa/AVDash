import Foundation

// MARK: - Widget Data Models
//
// Simplified data models for sharing with iOS/macOS widgets via App Groups.
// These are designed to be easily serialized to/from JSON.

public struct PeriodicAveragesWidgetData: Codable, Sendable {
    public let period: String // "24h", "7d", "30d"
    public let timestamp: Date
    public let series: [SeriesData]

    public struct SeriesData: Codable, Sendable {
        public let id: String
        public let label: String
        public let colorRed: Double
        public let colorGreen: Double
        public let colorBlue: Double
        public let values: [Double?] // Normalized [0, 1] values

        public init(id: String, label: String, colorRed: Double, colorGreen: Double, colorBlue: Double, values: [Double?]) {
            self.id = id
            self.label = label
            self.colorRed = colorRed
            self.colorGreen = colorGreen
            self.colorBlue = colorBlue
            self.values = values
        }
    }

    public init(period: String, timestamp: Date, series: [SeriesData]) {
        self.period = period
        self.timestamp = timestamp
        self.series = series
    }
}

public struct ActivityHeatmapWidgetData: Codable, Sendable {
    public let metric: String // "All", "CPU", "GPU", "ANE", "Press", "Pwr", "Net"
    public let timestamp: Date
    public let cells: [[Double]] // [day][hour] intensity values 0...1
    public let columnCount: Int

    public init(metric: String, timestamp: Date, cells: [[Double]], columnCount: Int) {
        self.metric = metric
        self.timestamp = timestamp
        self.cells = cells
        self.columnCount = columnCount
    }
}

// MARK: - Widget Storage Helper

public enum WidgetStorage {
    public static let sharedSuiteName = "group.com.chrisizatt.PodcastPreview"

    public static func savePeriodicAveragesData(_ data: PeriodicAveragesWidgetData) {
        guard let userDefaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        if let encoded = try? JSONEncoder().encode(data) {
            userDefaults.set(encoded, forKey: "periodicAveragesWidgetData")
        }
    }

    public static func loadPeriodicAveragesData() -> PeriodicAveragesWidgetData? {
        guard let userDefaults = UserDefaults(suiteName: sharedSuiteName),
              let data = userDefaults.data(forKey: "periodicAveragesWidgetData") else { return nil }
        return try? JSONDecoder().decode(PeriodicAveragesWidgetData.self, from: data)
    }

    public static func saveActivityHeatmapData(_ data: ActivityHeatmapWidgetData) {
        guard let userDefaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        if let encoded = try? JSONEncoder().encode(data) {
            userDefaults.set(encoded, forKey: "activityHeatmapWidgetData")
        }
    }

    public static func loadActivityHeatmapData() -> ActivityHeatmapWidgetData? {
        guard let userDefaults = UserDefaults(suiteName: sharedSuiteName),
              let data = userDefaults.data(forKey: "activityHeatmapWidgetData") else { return nil }
        return try? JSONDecoder().decode(ActivityHeatmapWidgetData.self, from: data)
    }
}
