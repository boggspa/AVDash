import Foundation
import PodcastPreviewShared

public enum HardwareInsightWindow: String, CaseIterable, Codable, Sendable {
    case daily
    case weekly
    case monthly

    public var trailingDuration: TimeInterval {
        switch self {
        case .daily:
            return 24 * 60 * 60
        case .weekly:
            return 7 * 24 * 60 * 60
        case .monthly:
            return 30 * 24 * 60 * 60
        }
    }

    public var insightSummaryBucketIntervalSeconds: Int {
        switch self {
        case .daily:
            return 60
        case .weekly:
            return 5 * 60
        case .monthly:
            return 60 * 60
        }
    }

    public func range(anchoredAt anchorDate: Date) -> DateInterval {
        DateInterval(
            start: anchorDate.addingTimeInterval(-trailingDuration),
            end: anchorDate
        )
    }
}

public enum HardwareInsightDaypart: String, CaseIterable, Codable, Sendable {
    case overnight
    case morning
    case afternoon
    case evening

    public init(hour: Int) {
        switch hour {
        case 6..<12:
            self = .morning
        case 12..<18:
            self = .afternoon
        case 18..<24:
            self = .evening
        default:
            self = .overnight
        }
    }
}

public enum HardwareInsightTrendDirection: String, CaseIterable, Codable, Sendable {
    case rising
    case falling
    case flat
    case oscillating
}

public enum HardwareInsightCadence: String, CaseIterable, Codable, Sendable {
    case quiet
    case bursty
    case steady
    case sustained
}

public struct HardwareInsightPeakWindow: Codable, Equatable, Sendable {
    public let bucketStart: Date
    public let bucketDurationSeconds: Int
    public let peakValue: Double
    public let coverageRatio: Double

    public init(
        bucketStart: Date,
        bucketDurationSeconds: Int,
        peakValue: Double,
        coverageRatio: Double
    ) {
        self.bucketStart = bucketStart
        self.bucketDurationSeconds = bucketDurationSeconds
        self.peakValue = peakValue
        self.coverageRatio = coverageRatio
    }
}

public struct HardwareMetricInsight: Codable, Equatable, Sendable {
    public let window: HardwareInsightWindow?
    public let range: DateInterval
    public let summary: HardwareHistoryMetricSummary
    public let peakWindow: HardwareInsightPeakWindow?
    public let busiestHourOfDay: Int?
    public let busiestDaypart: HardwareInsightDaypart?
    public let spikeBucketCount: Int
    public let idleBucketCount: Int
    public let trendDirection: HardwareInsightTrendDirection
    public let activityCadence: HardwareInsightCadence
    public let variabilityRatio: Double?
    public let longestSpikeStreak: Int
    public let longestIdleStreak: Int
    public let peakRecencyRatio: Double?

    public init(
        window: HardwareInsightWindow?,
        range: DateInterval,
        summary: HardwareHistoryMetricSummary,
        peakWindow: HardwareInsightPeakWindow?,
        busiestHourOfDay: Int?,
        busiestDaypart: HardwareInsightDaypart?,
        spikeBucketCount: Int,
        idleBucketCount: Int = 0,
        trendDirection: HardwareInsightTrendDirection = .flat,
        activityCadence: HardwareInsightCadence = .steady,
        variabilityRatio: Double? = nil,
        longestSpikeStreak: Int = 0,
        longestIdleStreak: Int = 0,
        peakRecencyRatio: Double? = nil
    ) {
        self.window = window
        self.range = range
        self.summary = summary
        self.peakWindow = peakWindow
        self.busiestHourOfDay = busiestHourOfDay
        self.busiestDaypart = busiestDaypart
        self.spikeBucketCount = spikeBucketCount
        self.idleBucketCount = idleBucketCount
        self.trendDirection = trendDirection
        self.activityCadence = activityCadence
        self.variabilityRatio = variabilityRatio
        self.longestSpikeStreak = longestSpikeStreak
        self.longestIdleStreak = longestIdleStreak
        self.peakRecencyRatio = peakRecencyRatio
    }
}

#if os(macOS)
public actor HardwareInsightsService {
    private let historyReader: any HardwareHistoryQuerying
    private let calendar: Calendar

    public init(
        historyReader: any HardwareHistoryQuerying,
        calendar: Calendar = .current
    ) {
        self.historyReader = historyReader
        self.calendar = calendar
    }

    public func metricInsight(
        for key: HardwareMetricKey,
        in range: DateInterval,
        summaryBucketIntervalSeconds: Int
    ) async -> HardwareMetricInsight {
        let summary = await historyReader.metricSummary(
            for: key,
            in: range,
            bucketIntervalSeconds: summaryBucketIntervalSeconds
        )
        return HardwareMetricInsight(
            window: nil,
            range: range,
            summary: summary,
            peakWindow: nil,
            busiestHourOfDay: nil,
            busiestDaypart: nil,
            spikeBucketCount: 0,
            trendDirection: .flat,
            activityCadence: .steady,
            variabilityRatio: nil,
            longestSpikeStreak: 0,
            longestIdleStreak: 0,
            peakRecencyRatio: nil
        )
    }

    public func deviceMetricInsight(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        summaryBucketIntervalSeconds: Int
    ) async -> HardwareMetricInsight {
        let summary = await historyReader.deviceMetricSummary(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            bucketIntervalSeconds: summaryBucketIntervalSeconds
        )
        return HardwareMetricInsight(
            window: nil,
            range: range,
            summary: summary,
            peakWindow: nil,
            busiestHourOfDay: nil,
            busiestDaypart: nil,
            spikeBucketCount: 0,
            trendDirection: .flat,
            activityCadence: .steady,
            variabilityRatio: nil,
            longestSpikeStreak: 0,
            longestIdleStreak: 0,
            peakRecencyRatio: nil
        )
    }

    // MARK: - Narrative Methods for Consuming Code

    public func metricNarrativeFacts(
        for key: HardwareMetricKey,
        in range: DateInterval
    ) async -> [CompanionKeyValueRow] {
        let insight = await metricInsight(
            for: key,
            in: range,
            summaryBucketIntervalSeconds: 60
        )
        return [
            CompanionKeyValueRow(label: "Average", value: String(format: "%.2f", insight.summary.average), tint: .slate),
            CompanionKeyValueRow(label: "Peak", value: String(format: "%.2f", insight.summary.peak), tint: .slate),
            CompanionKeyValueRow(label: "Minimum", value: String(format: "%.2f", insight.summary.minimum), tint: .slate)
        ]
    }

    public func metricNarrativeFacts(
        for key: HardwareMetricKey,
        window: HardwareInsightWindow,
        anchorDate: Date = Date()
    ) async -> [String] {
        let range = window.range(anchoredAt: anchorDate)
        let rows = await metricNarrativeFacts(for: key, in: range)
        return rows.map { "\($0.label): \($0.value)" }
    }

    public func deviceMetricNarrativeFacts(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval
    ) async -> [CompanionKeyValueRow] {
        let insight = await deviceMetricInsight(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            summaryBucketIntervalSeconds: 60
        )
        return [
            CompanionKeyValueRow(label: "Average", value: String(format: "%.2f", insight.summary.average), tint: .slate),
            CompanionKeyValueRow(label: "Peak", value: String(format: "%.2f", insight.summary.peak), tint: .slate),
            CompanionKeyValueRow(label: "Minimum", value: String(format: "%.2f", insight.summary.minimum), tint: .slate)
        ]
    }

    public func deviceMetricNarrativeFacts(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        window: HardwareInsightWindow,
        anchorDate: Date = Date()
    ) async -> [String] {
        let range = window.range(anchoredAt: anchorDate)
        let rows = await deviceMetricNarrativeFacts(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range
        )
        return rows.map { "\($0.label): \($0.value)" }
    }

    public func combinedMetricNarrativeFacts(
        for keys: [HardwareMetricKey],
        in range: DateInterval
    ) async -> [CompanionKeyValueRow] {
        var rows: [CompanionKeyValueRow] = []
        for key in keys {
            let facts = await metricNarrativeFacts(for: key, in: range)
            rows.append(contentsOf: facts)
        }
        return rows
    }

    public func combinedMetricNarrativeFacts(
        primaryKey: HardwareMetricKey,
        secondaryKey: HardwareMetricKey,
        window: HardwareInsightWindow,
        anchorDate: Date = Date()
    ) async -> [String] {
        let range = window.range(anchoredAt: anchorDate)
        let rows = await combinedMetricNarrativeFacts(for: [primaryKey, secondaryKey], in: range)
        return rows.map { "\($0.label): \($0.value)" }
    }

    // MARK: - Convenience Methods for Old API

    public func metricInsight(
        for key: HardwareMetricKey,
        window: HardwareInsightWindow,
        anchorDate: Date
    ) async -> HardwareMetricInsight {
        let range = window.range(anchoredAt: anchorDate)
        return await metricInsight(
            for: key,
            in: range,
            summaryBucketIntervalSeconds: window.insightSummaryBucketIntervalSeconds
        )
    }

    public func metricInsight(
        for key: HardwareMetricKey,
        window: HardwareInsightWindow
    ) async -> HardwareMetricInsight {
        await metricInsight(for: key, window: window, anchorDate: Date())
    }

    public func deviceMetricInsight(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        window: HardwareInsightWindow,
        anchorDate: Date
    ) async -> HardwareMetricInsight {
        let range = window.range(anchoredAt: anchorDate)
        return await deviceMetricInsight(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            summaryBucketIntervalSeconds: window.insightSummaryBucketIntervalSeconds
        )
    }

    public func deviceMetricInsight(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        window: HardwareInsightWindow
    ) async -> HardwareMetricInsight {
        await deviceMetricInsight(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            window: window,
            anchorDate: Date()
        )
    }
}
#endif
