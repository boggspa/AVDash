import Foundation

public struct HardwareHistoryStoreLocation: Sendable {
    public let rootURL: URL
    public let databaseURL: URL
    public let exists: Bool
    public let isReadable: Bool
    public let fileSizeBytes: Int64?
    public let modificationDate: Date?

    public var displayPath: String {
        (databaseURL.path as NSString).abbreviatingWithTildeInPath
    }
}

public struct HardwareHistoryMigrationAssessment: Sendable {
    public let destination: HardwareHistoryStoreLocation
    public let sources: [HardwareHistoryStoreLocation]

    public var hasImportableSources: Bool {
        !sources.isEmpty
    }

    public var importableSourceCount: Int {
        sources.count
    }

    public var newestSourceModificationDate: Date? {
        sources.compactMap(\.modificationDate).max()
    }

    public var needsImport: Bool {
        guard hasImportableSources else { return false }
        guard destination.exists else { return true }
        guard let newestSourceModificationDate else { return false }
        guard let destinationModificationDate = destination.modificationDate else { return true }
        return newestSourceModificationDate.timeIntervalSince(destinationModificationDate) > 1
    }
}

#if os(macOS)
import GRDB
import Darwin

public final class HardwareHistoryDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    public init(rootURL: URL? = nil) throws {
        let dbURL = Self.databaseURL(rootURL: rootURL)
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            // Cap WAL file at 1 MB so checkpoint writes stay bounded.
            try db.execute(sql: "PRAGMA journal_size_limit=1048576")
        }

        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try queue.write { db in
            try Self.createSchema(db)
        }
        self.dbQueue = queue
    }

    static func databaseURL(rootURL: URL? = nil) -> URL {
        resolveURL(rootURL: rootURL)
    }

    public static func userApplicationSupportRootURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    public static func localApplicationSupportRootURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
    }

    public static func inspectStore(rootURL: URL?) -> HardwareHistoryStoreLocation? {
        guard let rootURL else { return nil }
        let databaseURL = databaseURL(rootURL: rootURL)
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: databaseURL.path)
        let isReadable = fileManager.isReadableFile(atPath: databaseURL.path)

        let fileSizeBytes: Int64?
        let modificationDate: Date?
        if exists, let attributes = try? fileManager.attributesOfItem(atPath: databaseURL.path) {
            fileSizeBytes = (attributes[.size] as? NSNumber)?.int64Value
            modificationDate = attributes[.modificationDate] as? Date
        } else {
            fileSizeBytes = nil
            modificationDate = nil
        }

        return HardwareHistoryStoreLocation(
            rootURL: rootURL,
            databaseURL: databaseURL,
            exists: exists,
            isReadable: isReadable,
            fileSizeBytes: fileSizeBytes,
            modificationDate: modificationDate
        )
    }

    public static func assessMigration(
        fromSourceRootURLs sourceRootURLs: [URL],
        intoRootURL destinationRootURL: URL?
    ) -> HardwareHistoryMigrationAssessment? {
        guard let destination = inspectStore(rootURL: destinationRootURL) else { return nil }

        var seenDatabasePaths: Set<String> = [destination.databaseURL.standardizedFileURL.path]
        let sources = sourceRootURLs.compactMap { rootURL -> HardwareHistoryStoreLocation? in
            guard let location = inspectStore(rootURL: rootURL), location.exists else { return nil }
            let standardizedPath = location.databaseURL.standardizedFileURL.path
            guard seenDatabasePaths.contains(standardizedPath) == false else { return nil }
            seenDatabasePaths.insert(standardizedPath)
            return location
        }

        return HardwareHistoryMigrationAssessment(
            destination: destination,
            sources: sources
        )
    }

    static func importAvailableUserHistoryIfNeeded(intoRootURL rootURL: URL?) throws -> Bool {
        guard geteuid() == 0 else { return false }
        guard let destinationRootURL = rootURL else { return false }

        var sourceRootURLs = localUserApplicationSupportRootURLs()
        if let activeConsoleRootURL = activeConsoleUserApplicationSupportRootURL() {
            sourceRootURLs.removeAll {
                $0.standardizedFileURL == activeConsoleRootURL.standardizedFileURL
            }
            sourceRootURLs.append(activeConsoleRootURL)
        }

        var didImportAnyHistory = false
        for sourceRootURL in sourceRootURLs {
            let imported = try importHistoryIfNeeded(
                fromRootURL: sourceRootURL,
                intoRootURL: destinationRootURL
            )
            didImportAnyHistory = didImportAnyHistory || imported
        }

        return didImportAnyHistory
    }

    static func importHistoryIfNeeded(
        fromRootURL sourceRootURL: URL,
        intoRootURL destinationRootURL: URL
    ) throws -> Bool {
        let sourceURL = databaseURL(rootURL: sourceRootURL)
        let destinationURL = databaseURL(rootURL: destinationRootURL)

        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            return false
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return false
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) == false {
            try backupDatabase(from: sourceURL, to: destinationURL)
            return true
        }

        try mergeDatabase(from: sourceURL, into: destinationURL)
        return true
    }

    private static func createSchema(_ db: Database) throws {
        try db.execute(sql: "DROP TABLE IF EXISTS raw_frames")
        try db.execute(sql: "DROP TABLE IF EXISTS minute_rollups")
        try db.execute(sql: "DROP TABLE IF EXISTS hourly_rollups")

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS metric_rollups (
                bucket_start_ms INTEGER NOT NULL,
                bucket_duration_s INTEGER NOT NULL,
                metric_key TEXT NOT NULL,
                device_id TEXT NOT NULL DEFAULT '',
                device_kind TEXT NOT NULL DEFAULT '',
                observed_count INTEGER NOT NULL,
                frame_count INTEGER NOT NULL,
                estimated_observed_s INTEGER NOT NULL,
                min_value REAL NOT NULL,
                max_value REAL NOT NULL,
                avg_value REAL NOT NULL,
                last_value REAL NOT NULL,
                PRIMARY KEY (bucket_start_ms, bucket_duration_s, metric_key, device_kind, device_id)
            )
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS dimension_snapshots (
                bucket_start_ms INTEGER NOT NULL,
                bucket_duration_s INTEGER NOT NULL,
                dimension_key TEXT NOT NULL,
                device_id TEXT NOT NULL DEFAULT '',
                device_kind TEXT NOT NULL DEFAULT '',
                dimension_value TEXT NOT NULL,
                PRIMARY KEY (bucket_start_ms, bucket_duration_s, dimension_key, device_kind, device_id)
            )
            """)

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_metric_rollups_lookup
            ON metric_rollups (metric_key, device_id, device_kind, bucket_duration_s, bucket_start_ms)
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS process_rollups (
                bucket_start_ms INTEGER NOT NULL,
                bucket_duration_s INTEGER NOT NULL,
                process_key TEXT NOT NULL,
                bundle_identifier TEXT NOT NULL DEFAULT '',
                process_name TEXT NOT NULL,
                observed_count INTEGER NOT NULL,
                estimated_observed_s INTEGER NOT NULL,
                avg_cpu_percent REAL NOT NULL,
                max_cpu_percent REAL NOT NULL,
                avg_ram_mb REAL NOT NULL,
                max_ram_mb REAL NOT NULL,
                gpu_active_ratio REAL NOT NULL,
                gpu_active_count INTEGER NOT NULL,
                avg_gpu_time_ns INTEGER NOT NULL DEFAULT 0,
                max_gpu_time_ns INTEGER NOT NULL DEFAULT 0,
                avg_power_score REAL NOT NULL,
                last_uptime_seconds REAL,
                PRIMARY KEY (bucket_start_ms, bucket_duration_s, process_key)
            )
            """)

        try ensureColumn(
            named: "avg_gpu_time_ns",
            in: "process_rollups",
            definition: "INTEGER NOT NULL DEFAULT 0",
            db: db
        )
        try ensureColumn(
            named: "max_gpu_time_ns",
            in: "process_rollups",
            definition: "INTEGER NOT NULL DEFAULT 0",
            db: db
        )

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_process_rollups_lookup
            ON process_rollups (process_key, bucket_duration_s, bucket_start_ms)
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS hardware_events (
                timestamp_ms INTEGER NOT NULL,
                category TEXT NOT NULL,
                event_type TEXT NOT NULL,
                title TEXT NOT NULL,
                detail TEXT,
                severity INTEGER NOT NULL DEFAULT 0
            )
            """)

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_hardware_events_timestamp
            ON hardware_events (timestamp_ms)
            """)
    }

    private static func ensureColumn(
        named columnName: String,
        in tableName: String,
        definition: String,
        db: Database
    ) throws {
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
            .compactMap { row in
                row["name"] as String?
            }

        guard columns.contains(columnName) == false else { return }
        try db.execute(sql: "ALTER TABLE \(tableName) ADD COLUMN \(columnName) \(definition)")
    }

    private static func backupDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        var sourceConfiguration = Configuration()
        sourceConfiguration.readonly = true

        let sourceQueue = try DatabaseQueue(
            path: sourceURL.path,
            configuration: sourceConfiguration
        )
        let destinationQueue = try DatabaseQueue(path: destinationURL.path)
        try sourceQueue.backup(to: destinationQueue)
    }

    private static func mergeDatabase(from sourceURL: URL, into destinationURL: URL) throws {
        let destinationQueue = try DatabaseQueue(path: destinationURL.path)

        try destinationQueue.write { db in
            try createSchema(db)
            try db.execute(sql: "ATTACH DATABASE ? AS source_history", arguments: [sourceURL.path])
            defer {
                try? db.execute(sql: "DETACH DATABASE source_history")
            }

            let sourceTables = try attachedTableNames(schema: "source_history", db: db)

            if sourceTables.contains("metric_rollups") {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO metric_rollups (
                        bucket_start_ms,
                        bucket_duration_s,
                        metric_key,
                        device_id,
                        device_kind,
                        observed_count,
                        frame_count,
                        estimated_observed_s,
                        min_value,
                        max_value,
                        avg_value,
                        last_value
                    )
                    SELECT
                        bucket_start_ms,
                        bucket_duration_s,
                        metric_key,
                        device_id,
                        device_kind,
                        observed_count,
                        frame_count,
                        estimated_observed_s,
                        min_value,
                        max_value,
                        avg_value,
                        last_value
                    FROM source_history.metric_rollups
                    """)
            }

            if sourceTables.contains("dimension_snapshots") {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO dimension_snapshots (
                        bucket_start_ms,
                        bucket_duration_s,
                        dimension_key,
                        device_id,
                        device_kind,
                        dimension_value
                    )
                    SELECT
                        bucket_start_ms,
                        bucket_duration_s,
                        dimension_key,
                        device_id,
                        device_kind,
                        dimension_value
                    FROM source_history.dimension_snapshots
                    """)
            }

            if sourceTables.contains("process_rollups") {
                let sourceProcessColumns = try attachedColumnNames(
                    in: "process_rollups",
                    schema: "source_history",
                    db: db
                )
                let avgGPUTimeExpression = sourceProcessColumns.contains("avg_gpu_time_ns")
                    ? "avg_gpu_time_ns"
                    : "0"
                let maxGPUTimeExpression = sourceProcessColumns.contains("max_gpu_time_ns")
                    ? "max_gpu_time_ns"
                    : "0"

                try db.execute(sql: """
                    INSERT OR REPLACE INTO process_rollups (
                        bucket_start_ms,
                        bucket_duration_s,
                        process_key,
                        bundle_identifier,
                        process_name,
                        observed_count,
                        estimated_observed_s,
                        avg_cpu_percent,
                        max_cpu_percent,
                        avg_ram_mb,
                        max_ram_mb,
                        gpu_active_ratio,
                        gpu_active_count,
                        avg_gpu_time_ns,
                        max_gpu_time_ns,
                        avg_power_score,
                        last_uptime_seconds
                    )
                    SELECT
                        bucket_start_ms,
                        bucket_duration_s,
                        process_key,
                        bundle_identifier,
                        process_name,
                        observed_count,
                        estimated_observed_s,
                        avg_cpu_percent,
                        max_cpu_percent,
                        avg_ram_mb,
                        max_ram_mb,
                        gpu_active_ratio,
                        gpu_active_count,
                        \(avgGPUTimeExpression),
                        \(maxGPUTimeExpression),
                        avg_power_score,
                        last_uptime_seconds
                    FROM source_history.process_rollups
                    """)
            }

            if sourceTables.contains("hardware_events") {
                try db.execute(sql: """
                    INSERT INTO hardware_events (
                        timestamp_ms,
                        category,
                        event_type,
                        title,
                        detail,
                        severity
                    )
                    SELECT
                        source.timestamp_ms,
                        source.category,
                        source.event_type,
                        source.title,
                        source.detail,
                        source.severity
                    FROM source_history.hardware_events AS source
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM hardware_events AS existing
                        WHERE existing.timestamp_ms = source.timestamp_ms
                          AND existing.category = source.category
                          AND existing.event_type = source.event_type
                          AND existing.title = source.title
                          AND IFNULL(existing.detail, '') = IFNULL(source.detail, '')
                          AND existing.severity = source.severity
                    )
                    """)
            }
        }
    }

    private static func attachedTableNames(
        schema: String,
        db: Database
    ) throws -> Set<String> {
        Set(
            try String.fetchAll(
                db,
                sql: "SELECT name FROM \(schema).sqlite_master WHERE type = 'table'"
            )
        )
    }

    private static func attachedColumnNames(
        in tableName: String,
        schema: String,
        db: Database
    ) throws -> Set<String> {
        Set(
            try Row.fetchAll(db, sql: "PRAGMA \(schema).table_info(\(tableName))")
                .compactMap { row in
                    row["name"] as String?
                }
        )
    }

    private static func activeConsoleUserApplicationSupportRootURL() -> URL? {
        var consoleStat = stat()
        guard stat("/dev/console", &consoleStat) == 0 else { return nil }

        let userID = consoleStat.st_uid
        guard userID != 0, let userEntry = getpwuid(userID) else { return nil }

        let homeDirectory = String(cString: userEntry.pointee.pw_dir)
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
    }

    private static func localUserApplicationSupportRootURLs() -> [URL] {
        let usersDirectoryURL = URL(fileURLWithPath: "/Users", isDirectory: true)
        guard let homeDirectoryURLs = try? FileManager.default.contentsOfDirectory(
            at: usersDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return homeDirectoryURLs
            .filter(shouldIncludeUserHomeDirectory(_:))
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { homeDirectoryURL in
                homeDirectoryURL
                    .appendingPathComponent("Library")
                    .appendingPathComponent("Application Support")
            }
    }

    private static func shouldIncludeUserHomeDirectory(_ homeDirectoryURL: URL) -> Bool {
        guard homeDirectoryURL.lastPathComponent != "Shared" else { return false }

        do {
            let resourceValues = try homeDirectoryURL.resourceValues(forKeys: [.isDirectoryKey])
            return resourceValues.isDirectory == true
        } catch {
            return false
        }
    }

    private static func resolveURL(rootURL: URL?) -> URL {
        let base = rootURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("PodcastPreview")
            .appendingPathComponent("HardwareTelemetry")
            .appendingPathComponent("telemetry.db")
    }
}
#endif
