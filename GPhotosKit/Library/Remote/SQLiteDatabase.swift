import Foundation
import SQLite3

/// A minimal wrapper over the system SQLite: prepared statements with positional binds,
/// WAL journaling, and transactions. Not thread-safe; owned by one actor.
final class SQLiteDatabase {
  enum Value {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private var handle: OpaquePointer?
  private var statements: [String: OpaquePointer] = [:]
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
      sqlite3_close(handle)
      throw Failure(description: message)
    }
    try execute("PRAGMA journal_mode = WAL")
    try execute("PRAGMA synchronous = NORMAL")
  }

  deinit {
    for statement in statements.values { sqlite3_finalize(statement) }
    sqlite3_close(handle)
  }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
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

  /// Runs a statement that returns no rows.
  func run(_ sql: String, _ values: [Value] = []) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_reset(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
  }

  /// Calls `row` for each result row.
  func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
    let statement = try prepare(sql, values)
    defer { sqlite3_reset(statement) }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return }
      guard result == SQLITE_ROW else { throw error() }
      try row(Row(statement: statement))
    }
  }

  struct Row {
    let statement: OpaquePointer

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func optionalInt(_ column: Int32) -> Int64? { isNull(column) ? nil : int(column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }

    func text(_ column: Int32) -> String? {
      guard let pointer = sqlite3_column_text(statement, column) else { return nil }
      return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data? {
      guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
      return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }
  }

  private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
    let statement: OpaquePointer
    if let cached = statements[sql] {
      statement = cached
    } else {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw error() }
      statements[sql] = prepared
      statement = prepared
    }
    sqlite3_clear_bindings(statement)
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .int(let int): sqlite3_bind_int64(statement, index, int)
      case .double(let double): sqlite3_bind_double(statement, index, double)
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, Self.transient)
      case .blob(let data):
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
      case .null: sqlite3_bind_null(statement, index)
      }
    }
    return statement
  }

  private func error() -> Failure {
    Failure(description: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error")
  }
}

extension SQLiteDatabase.Value {
  static func optional(_ value: Int?) -> Self { value.map { .int(Int64($0)) } ?? .null }
  static func optional(_ value: Double?) -> Self { value.map { .double($0) } ?? .null }
  static func optional(_ value: String?) -> Self { value.map { .text($0) } ?? .null }
  static func optional(_ value: Data?) -> Self { value.map { .blob($0) } ?? .null }
  static func optional(_ value: Date?) -> Self { value.map { .double($0.timeIntervalSince1970) } ?? .null }
  static func bool(_ value: Bool) -> Self { .int(value ? 1 : 0) }
}
