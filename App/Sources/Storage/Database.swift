import Foundation
import SQLite3
import YearBarcodeCore

enum DatabaseError: Error, LocalizedError {
    case open(String)
    case statement(String)

    var errorDescription: String? {
        switch self {
        case .open(let message), .statement(let message): return message
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin SQLite wrapper. All access is serialized through one lock; callers
/// may use it from any thread.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    static func openDefault() throws -> Database {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = directory.appendingPathComponent("YearBarcode.sqlite")
        let database = try Database(url: url)
        // Readable while the device is locked (after first unlock) so background
        // continuation can checkpoint.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        return database
    }

    init(url: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS generation (
            id TEXT PRIMARY KEY,
            year INTEGER NOT NULL,
            cutoff REAL NOT NULL,
            time_zone TEXT NOT NULL,
            settings TEXT NOT NULL,
            access TEXT NOT NULL,
            analysis_version INTEGER NOT NULL,
            layout_version INTEGER NOT NULL,
            status TEXT NOT NULL,
            interruption TEXT,
            checkpoint INTEGER NOT NULL DEFAULT 0,
            missing_date_count INTEGER NOT NULL,
            invalid_date_count INTEGER NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS manifest (
            generation_id TEXT NOT NULL REFERENCES generation(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            asset_id TEXT NOT NULL,
            revision TEXT NOT NULL,
            capture_date REAL NOT NULL,
            day_year INTEGER NOT NULL,
            day_ordinal INTEGER NOT NULL,
            status TEXT NOT NULL,
            PRIMARY KEY (generation_id, position)
        );
        CREATE INDEX IF NOT EXISTS manifest_status ON manifest(generation_id, status);
        CREATE TABLE IF NOT EXISTS photo_analysis (
            asset_id TEXT NOT NULL,
            revision TEXT NOT NULL,
            analysis_version INTEGER NOT NULL,
            r REAL NOT NULL, g REAL NOT NULL, b REAL NOT NULL,
            exclusion TEXT,
            confidence REAL NOT NULL,
            difference_hash INTEGER NOT NULL,
            content_hash INTEGER NOT NULL,
            PRIMARY KEY (asset_id, revision, analysis_version)
        );
        CREATE TABLE IF NOT EXISTS artwork (
            generation_id TEXT PRIMARY KEY REFERENCES generation(id) ON DELETE CASCADE,
            settings TEXT NOT NULL,
            border_photos TEXT NOT NULL,
            export_path TEXT,
            updated_at REAL NOT NULL
        );
        """)
    }

    // MARK: - Primitive helpers

    func execute(_ sql: String) throws {
        try locked {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "SQLite error"
                sqlite3_free(error)
                throw DatabaseError.statement(message)
            }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    fileprivate func run(_ sql: String, _ bindings: [SQLValue], row: ((Statement) throws -> Void)? = nil) throws {
        try locked {
            var handle: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
                throw DatabaseError.statement(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(handle) }
            for (index, value) in bindings.enumerated() {
                let i = Int32(index + 1)
                switch value {
                case .int(let v): sqlite3_bind_int64(handle, i, v)
                case .double(let v): sqlite3_bind_double(handle, i, v)
                case .text(let v): sqlite3_bind_text(handle, i, v, -1, SQLITE_TRANSIENT)
                case .null: sqlite3_bind_null(handle, i)
                }
            }
            while true {
                let step = sqlite3_step(handle)
                if step == SQLITE_ROW {
                    try row?(Statement(handle: handle))
                } else if step == SQLITE_DONE {
                    break
                } else {
                    throw DatabaseError.statement(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }
}

fileprivate enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null

    static func optionalText(_ s: String?) -> SQLValue { s.map(SQLValue.text) ?? .null }
}

fileprivate struct Statement {
    let handle: OpaquePointer?
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(handle, i)) }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
    func text(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(handle, i) else { return nil }
        return String(cString: c)
    }
}

// MARK: - Records

struct GenerationRecord: Identifiable, Hashable, Sendable {
    var id: UUID
    var year: Int
    var cutoff: Date
    var timeZoneIdentifier: String
    var settings: ArtworkSettings
    var access: LibraryAccess
    var analysisVersion: Int
    var layoutVersion: Int
    var status: JobStatus
    var interruption: InterruptionReason?
    var checkpoint: Int
    var missingDateCount: Int
    var invalidDateCount: Int
    var createdAt: Date
}

struct ArtworkRecord: Hashable, Sendable {
    var generationID: UUID
    var settings: ArtworkSettings
    var borderPhotos: [BorderPhoto]
    var exportPath: String?
}

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

extension Database {
    // MARK: Generations

    func insert(snapshot: GenerationSnapshot) throws {
        try transaction {
            try run("""
            INSERT INTO generation (id, year, cutoff, time_zone, settings, access, analysis_version, layout_version, status, checkpoint, missing_date_count, invalid_date_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
            """, [
                .text(snapshot.id.uuidString), .int(Int64(snapshot.year)), .double(snapshot.cutoff.timeIntervalSince1970),
                .text(snapshot.timeZoneIdentifier), .text(try json(snapshot.settings)), .text(snapshot.access.rawValue),
                .int(Int64(snapshot.analysisVersion)), .int(Int64(snapshot.layoutVersion)), .text(JobStatus.analyzing.rawValue),
                .int(Int64(snapshot.missingDateCount)), .int(Int64(snapshot.invalidDateCount)), .double(Date().timeIntervalSince1970),
            ])
            for (position, entry) in snapshot.entries.enumerated() {
                try run("""
                INSERT INTO manifest (generation_id, position, asset_id, revision, capture_date, day_year, day_ordinal, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(snapshot.id.uuidString), .int(Int64(position)), .text(entry.assetID), .text(entry.revision),
                    .double(entry.captureDate.timeIntervalSince1970), .int(Int64(entry.day.year)), .int(Int64(entry.day.ordinal)),
                    .text(ItemStatus.pending.rawValue),
                ])
            }
            try run("INSERT INTO artwork (generation_id, settings, border_photos, updated_at) VALUES (?, ?, '[]', ?)",
                    [.text(snapshot.id.uuidString), .text(try json(snapshot.settings)), .double(Date().timeIntervalSince1970)])
        }
    }

    func generations() throws -> [GenerationRecord] {
        var result: [GenerationRecord] = []
        try run("SELECT \(Self.generationColumns) FROM generation ORDER BY created_at DESC", []) { result.append(try Self.generation(from: $0)) }
        return result
    }

    func generation(_ id: UUID) throws -> GenerationRecord? {
        var result: GenerationRecord?
        try run("SELECT \(Self.generationColumns) FROM generation WHERE id = ?", [.text(id.uuidString)]) { result = try Self.generation(from: $0) }
        return result
    }

    func setStatus(_ status: JobStatus, interruption: InterruptionReason? = nil, for id: UUID) throws {
        try run("UPDATE generation SET status = ?, interruption = ? WHERE id = ?",
                [.text(status.rawValue), .optionalText(interruption?.rawValue), .text(id.uuidString)])
    }

    func deleteGeneration(_ id: UUID) throws {
        try run("DELETE FROM generation WHERE id = ?", [.text(id.uuidString)])
    }

    private static let generationColumns = "id, year, cutoff, time_zone, settings, access, analysis_version, layout_version, status, interruption, checkpoint, missing_date_count, invalid_date_count, created_at"

    private static func generation(from s: Statement) throws -> GenerationRecord {
        GenerationRecord(
            id: UUID(uuidString: s.text(0) ?? "") ?? UUID(),
            year: s.int(1),
            cutoff: Date(timeIntervalSince1970: s.double(2)),
            timeZoneIdentifier: s.text(3) ?? "UTC",
            settings: (try? decoder.decode(ArtworkSettings.self, from: Data((s.text(4) ?? "").utf8))) ?? .default,
            access: LibraryAccess(rawValue: s.text(5) ?? "") ?? .full,
            analysisVersion: s.int(6),
            layoutVersion: s.int(7),
            status: JobStatus(rawValue: s.text(8) ?? "") ?? .interrupted,
            interruption: s.text(9).flatMap(InterruptionReason.init(rawValue:)),
            checkpoint: s.int(10),
            missingDateCount: s.int(11),
            invalidDateCount: s.int(12),
            createdAt: Date(timeIntervalSince1970: s.double(13))
        )
    }

    // MARK: Manifest

    func manifest(_ id: UUID) throws -> [(position: Int, entry: ManifestEntry, status: ItemStatus)] {
        var rows: [(position: Int, entry: ManifestEntry, status: ItemStatus)] = []
        try run("""
        SELECT position, asset_id, revision, capture_date, day_year, day_ordinal, status
        FROM manifest WHERE generation_id = ? ORDER BY position
        """, [.text(id.uuidString)]) { s in
            rows.append((
                position: s.int(0),
                entry: ManifestEntry(assetID: s.text(1) ?? "", revision: s.text(2) ?? "",
                              captureDate: Date(timeIntervalSince1970: s.double(3)),
                              day: DayKey(year: s.int(4), ordinal: s.int(5))),
                status: ItemStatus(rawValue: s.text(6) ?? "") ?? .pending
            ))
        }
        return rows
    }

    func snapshot(for record: GenerationRecord) throws -> GenerationSnapshot {
        GenerationSnapshot(
            id: record.id, year: record.year, cutoff: record.cutoff, timeZoneIdentifier: record.timeZoneIdentifier,
            settings: record.settings, access: record.access, analysisVersion: record.analysisVersion,
            layoutVersion: record.layoutVersion, entries: try manifest(record.id).map { $0.entry },
            missingDateCount: record.missingDateCount, invalidDateCount: record.invalidDateCount
        )
    }

    /// Records the outcome for a batch of items and advances the checkpoint atomically.
    func checkpoint(_ id: UUID, updates: [(position: Int, status: ItemStatus, analysis: PhotoAnalysis?)]) throws {
        guard !updates.isEmpty else { return }
        try transaction {
            for update in updates {
                if let analysis = update.analysis { try save(analysis) }
                try run("UPDATE manifest SET status = ? WHERE generation_id = ? AND position = ?",
                        [.text(update.status.rawValue), .text(id.uuidString), .int(Int64(update.position))])
            }
            try run("UPDATE generation SET checkpoint = (SELECT COUNT(*) FROM manifest WHERE generation_id = ? AND status != 'pending') WHERE id = ?",
                    [.text(id.uuidString), .text(id.uuidString)])
        }
    }

    /// Makes retryable items pending again (e.g. after the network returns).
    func resetRetryable(_ id: UUID) throws {
        try run("UPDATE manifest SET status = 'pending' WHERE generation_id = ? AND status = 'downloadFailed'", [.text(id.uuidString)])
    }

    // MARK: Analysis cache

    func analysis(assetID: String, revision: String, version: Int = Versions.analysis) throws -> PhotoAnalysis? {
        var result: PhotoAnalysis?
        try run("""
        SELECT r, g, b, exclusion, confidence, difference_hash, content_hash FROM photo_analysis
        WHERE asset_id = ? AND revision = ? AND analysis_version = ?
        """, [.text(assetID), .text(revision), .int(Int64(version))]) { s in
            result = PhotoAnalysis(
                assetID: assetID, revision: revision, analysisVersion: version,
                color: LinearRGB(r: s.double(0), g: s.double(1), b: s.double(2)),
                exclusion: s.text(3).flatMap(ExclusionReason.init(rawValue:)),
                confidence: s.double(4),
                fingerprint: ImageFingerprint(differenceHash: UInt64(bitPattern: s.int64(5)), contentHash: UInt64(bitPattern: s.int64(6)))
            )
        }
        return result
    }

    func save(_ analysis: PhotoAnalysis) throws {
        try run("""
        INSERT OR REPLACE INTO photo_analysis (asset_id, revision, analysis_version, r, g, b, exclusion, confidence, difference_hash, content_hash)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(analysis.assetID), .text(analysis.revision), .int(Int64(analysis.analysisVersion)),
            .double(analysis.color.r), .double(analysis.color.g), .double(analysis.color.b),
            .optionalText(analysis.exclusion?.rawValue), .double(analysis.confidence),
            .int(Int64(bitPattern: analysis.fingerprint.differenceHash)), .int(Int64(bitPattern: analysis.fingerprint.contentHash)),
        ])
    }

    /// Manifest items joined with their cached analyses, for building reports.
    func items(for record: GenerationRecord) throws -> [ManifestItem] {
        try manifest(record.id).map { row in
            let analysis = row.status == .analyzed
                ? try self.analysis(assetID: row.entry.assetID, revision: row.entry.revision, version: record.analysisVersion)
                : nil
            return ManifestItem(entry: row.entry, status: row.status, analysis: analysis)
        }
    }

    // MARK: Artwork

    func artwork(_ id: UUID) throws -> ArtworkRecord? {
        var result: ArtworkRecord?
        try run("SELECT settings, border_photos, export_path FROM artwork WHERE generation_id = ?", [.text(id.uuidString)]) { s in
            result = ArtworkRecord(
                generationID: id,
                settings: (try? decoder.decode(ArtworkSettings.self, from: Data((s.text(0) ?? "").utf8))) ?? .default,
                borderPhotos: (try? decoder.decode([BorderPhoto].self, from: Data((s.text(1) ?? "[]").utf8))) ?? [],
                exportPath: s.text(2)
            )
        }
        return result
    }

    func save(_ artwork: ArtworkRecord) throws {
        try run("""
        INSERT OR REPLACE INTO artwork (generation_id, settings, border_photos, export_path, updated_at) VALUES (?, ?, ?, ?, ?)
        """, [
            .text(artwork.generationID.uuidString), .text(try json(artwork.settings)), .text(try json(artwork.borderPhotos)),
            .optionalText(artwork.exportPath), .double(Date().timeIntervalSince1970),
        ])
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
