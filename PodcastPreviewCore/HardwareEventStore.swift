import Foundation

public enum HardwareEventCategory: String, Codable, CaseIterable, Sendable {
    case system
    case power
    case thermal
    case display
    case media
    case remote
}

public enum HardwareEventSeverity: Int, Codable, Sendable {
    case info = 0
    case caution = 1
    case highlight = 2
}

public struct HardwareTimelineEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let category: HardwareEventCategory
    public let type: String
    public let title: String
    public let detail: String?
    public let severity: HardwareEventSeverity

    public init(
        id: Int64,
        timestamp: Date,
        category: HardwareEventCategory,
        type: String,
        title: String,
        detail: String?,
        severity: HardwareEventSeverity
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.type = type
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

#if os(macOS)
import GRDB

public actor HardwareEventStore {
    public struct Configuration: Sendable {
        public let retentionDays: Int
        public let sweepIntervalSeconds: TimeInterval

        public init(retentionDays: Int = 90, sweepIntervalSeconds: TimeInterval = 3600) {
            self.retentionDays = max(1, retentionDays)
            self.sweepIntervalSeconds = max(300, sweepIntervalSeconds)
        }
    }

    private let database: HardwareHistoryDatabase
    private let configuration: Configuration
    private let calendar: Calendar
    private var lastRetentionSweepDate: Date?

    public init(database: HardwareHistoryDatabase, configuration: Configuration = Configuration()) {
        self.database = database
        self.configuration = configuration

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        self.calendar = calendar
    }

    public func append(
        category: HardwareEventCategory,
        type: String,
        title: String,
        detail: String? = nil,
        severity: HardwareEventSeverity = .info,
        timestamp: Date = Date()
    ) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO hardware_events
                        (timestamp_ms, category, event_type, title, detail, severity)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        Int64(timestamp.timeIntervalSince1970 * 1000),
                        category.rawValue,
                        type,
                        title,
                        detail,
                        severity.rawValue
                    ]
                )
            }

            try pruneIfNeeded(referenceDate: timestamp)
        } catch {
            logDebugError("HardwareEventStore append failed: \(error)")
        }
    }

    private func pruneIfNeeded(referenceDate: Date, force: Bool = false) throws {
        if !force,
           let lastRetentionSweepDate,
           referenceDate.timeIntervalSince(lastRetentionSweepDate) < configuration.sweepIntervalSeconds {
            return
        }

        let cutoffDate = calendar.date(
            byAdding: .day,
            value: -(configuration.retentionDays - 1),
            to: dayStart(for: referenceDate)
        ) ?? referenceDate
        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)

        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM hardware_events WHERE timestamp_ms < ?",
                arguments: [cutoffMs]
            )
        }
        lastRetentionSweepDate = referenceDate
    }

    private func dayStart(for timestamp: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day], from: timestamp)
        return calendar.date(from: components) ?? timestamp
    }

    private func logDebugError(_ message: String) {
        #if DEBUG
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        #endif
    }
}

public actor HardwareEventReader: HardwareEventQuerying {
    private let database: HardwareHistoryDatabase

    public init(database: HardwareHistoryDatabase) {
        self.database = database
    }

    public func events(
        in range: DateInterval,
        categories: [HardwareEventCategory]? = nil,
        limit: Int = 96
    ) async -> [HardwareTimelineEvent] {
        guard range.duration > 0 else { return [] }

        let startMs = Int64(range.start.timeIntervalSince1970 * 1000)
        let endMs = Int64(range.end.timeIntervalSince1970 * 1000)
        let effectiveLimit = max(1, limit)

        do {
            let rows = try await database.dbQueue.read { db in
                if let categories, !categories.isEmpty {
                    let categoryValues = categories.map(\.rawValue)
                    let placeholders = Array(repeating: "?", count: categoryValues.count).joined(separator: ", ")
                    var arguments = StatementArguments([
                        startMs,
                        endMs
                    ])
                    for value in categoryValues {
                        arguments += [value]
                    }
                    arguments += [effectiveLimit]

                    return try Row.fetchAll(
                        db,
                        sql: """
                            SELECT rowid, timestamp_ms, category, event_type, title, detail, severity
                            FROM hardware_events
                            WHERE timestamp_ms >= ?
                              AND timestamp_ms < ?
                              AND category IN (\(placeholders))
                            ORDER BY timestamp_ms ASC
                            LIMIT ?
                            """,
                        arguments: arguments
                    )
                }

                return try Row.fetchAll(
                    db,
                    sql: """
                        SELECT rowid, timestamp_ms, category, event_type, title, detail, severity
                        FROM hardware_events
                        WHERE timestamp_ms >= ?
                          AND timestamp_ms < ?
                        ORDER BY timestamp_ms ASC
                        LIMIT ?
                        """,
                    arguments: [startMs, endMs, effectiveLimit]
                )
            }

            return rows.compactMap { row in
                guard let category = HardwareEventCategory(rawValue: row["category"]) else { return nil }
                let severity = HardwareEventSeverity(rawValue: row["severity"]) ?? .info
                let timestampMs: Int64 = row["timestamp_ms"]
                let rowID: Int64 = row["rowid"]

                return HardwareTimelineEvent(
                    id: rowID,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0),
                    category: category,
                    type: row["event_type"],
                    title: row["title"],
                    detail: row["detail"],
                    severity: severity
                )
            }
        } catch {
            return []
        }
    }
}
#endif
