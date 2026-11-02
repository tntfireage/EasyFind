import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: Error, LocalizedError {
    case open(String)
    case prepare(String, String)
    case step(String)
    case exec(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "sqlite open failed: \(message)"
        case .prepare(let sql, let message): return "sqlite prepare failed: \(message) [\(sql)]"
        case .step(let message): return "sqlite step failed: \(message)"
        case .exec(let message): return "sqlite exec failed: \(message)"
        }
    }
}

final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        var connection: OpaquePointer?
        var flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        flags |= SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let result = sqlite3_open_v2(path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let connection { sqlite3_close_v2(connection) }
            throw SQLiteError.open(message)
        }
        handle = connection
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    func exec(_ sql: String) throws {
        guard let handle else { throw SQLiteError.exec("database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw SQLiteError.exec(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError.prepare(sql, "database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(sql, String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(database: handle, statement: statement)
    }

    func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version")
        _ = try statement.step()
        return Int32(statement.int64(0))
    }

    func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version)")
    }
}

final class SQLiteStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer

    init(database: OpaquePointer, statement: OpaquePointer) {
        self.database = database
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ index: Int32, _ value: Int) {
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    func bind(_ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(statement, index, value)
    }

    func bind(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteError.step(String(cString: sqlite3_errmsg(database)))
        }
    }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func text(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    func int64(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }
}