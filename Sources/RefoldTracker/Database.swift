import Foundation
import CSQLite

final class Database {
    private var handle: OpaquePointer?

    init() throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("RefoldTracker", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open_v2(root.appendingPathComponent("tracker.sqlite").path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw failure() }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), data BLOB NOT NULL)")
    }

    deinit { sqlite3_close(handle) }

    func load() throws -> Snapshot {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT data FROM state WHERE id=1", -1, &statement, nil) == SQLITE_OK
        else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return Snapshot() }
        guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(_ state: Snapshot) throws {
        let data = try JSONEncoder().encode(state)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO state(id,data) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                                -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let bound = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> NSError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
        return NSError(domain: "RefoldTracker.Storage", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}
