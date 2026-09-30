import CryptoKit
import Foundation
import SQLite3

public struct Note: Equatable, Sendable {
  public var date: String
  public var content: String
  public var updatedAt: String?

  public init(date: String, content: String, updatedAt: String?) {
    self.date = date
    self.content = content
    self.updatedAt = updatedAt
  }
}

public struct StoredImage: Sendable {
  public var id: String
  public var mimeType: String
  public var fileName: String
  public var width: Int?
  public var height: Int?
  public var data: Data
}

public struct StoreError: LocalizedError {
  public let message: String
  public var errorDescription: String? { message }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class NoteStore {
  public static let imageTypes: Set<String> = ["image/gif", "image/jpeg", "image/png", "image/svg+xml", "image/webp"]
  public static let maxImageBytes = 15_000_000
  public static let maxNoteBytes = 2_000_000

  public let url: URL
  private var db: OpaquePointer?
  private var statements: [String: OpaquePointer] = [:]
  private let timestamps: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  public static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NoteRepo/notes.sqlite3")
  }

  public init(url: URL = NoteStore.defaultURL) throws {
    self.url = url
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
      throw StoreError(message: "Could not open \(url.path)")
    }
    sqlite3_create_function_v2(
      db, "has_note_content", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
      { context, _, values in
        let text = values?[0].flatMap { sqlite3_value_text($0) }.map { String(cString: $0) } ?? ""
        sqlite3_result_int(context, Outline.hasContent(text) ? 1 : 0)
      }, nil, nil, nil)
    try exec(
      """
      PRAGMA busy_timeout = 5000;
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      CREATE TABLE IF NOT EXISTS notes (
        date TEXT PRIMARY KEY,
        content TEXT NOT NULL DEFAULT '',
        updated_at TEXT
      ) STRICT;
      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS images (
        id TEXT PRIMARY KEY,
        checksum TEXT NOT NULL UNIQUE,
        mime_type TEXT NOT NULL,
        file_name TEXT NOT NULL,
        width INTEGER,
        height INTEGER,
        byte_size INTEGER NOT NULL,
        data BLOB NOT NULL,
        created_at TEXT NOT NULL
      ) STRICT;
      """)
    for suffix in ["", "-shm", "-wal"] {
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path + suffix)
    }
  }

  deinit {
    statements.values.forEach { sqlite3_finalize($0) }
    sqlite3_close_v2(db)
  }

  private var lastError: String { String(cString: sqlite3_errmsg(db)) }

  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError(message: lastError) }
  }

  private enum Value {
    case text(String)
    case int(Int)
    case blob(Data)
    case null
  }

  private func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) -> Void = { _ in }) throws {
    let statement: OpaquePointer
    if let cached = statements[sql] {
      statement = cached
    } else {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
        throw StoreError(message: lastError)
      }
      statements[sql] = prepared
      statement = prepared
    }
    defer {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
    }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
      case .int(let number): sqlite3_bind_int64(statement, index, Int64(number))
      case .blob(let data):
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
      case .null: sqlite3_bind_null(statement, index)
      }
    }
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW {
        row(statement)
      } else if result == SQLITE_DONE {
        return
      } else {
        throw StoreError(message: lastError)
      }
    }
  }

  private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }

  private func int(_ statement: OpaquePointer, _ column: Int32) -> Int? {
    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, column))
  }

  private func notes(_ sql: String, _ values: [Value]) throws -> [Note] {
    var notes: [Note] = []
    try query(sql, values) { row in
      notes.append(Note(date: self.text(row, 0) ?? "", content: self.text(row, 1) ?? "", updatedAt: self.text(row, 2)))
    }
    return notes
  }

  public func get(_ date: String) throws -> Note {
    try notes("SELECT date, content, updated_at FROM notes WHERE date = ?", [.text(date)]).first
      ?? Note(date: date, content: "", updatedAt: nil)
  }

  public func has(_ date: String) throws -> Bool {
    var present = false
    try query("SELECT 1 FROM notes WHERE date = ? AND has_note_content(content) = 1", [.text(date)]) { _ in
      present = true
    }
    return present
  }

  private func put(_ date: String, _ content: String) throws -> Note {
    guard content.utf8.count <= NoteStore.maxNoteBytes else { throw StoreError(message: "Note is too large") }
    let updatedAt = timestamps.string(from: Date())
    try query(
      """
      INSERT INTO notes (date, content, updated_at) VALUES (?, ?, ?)
      ON CONFLICT(date) DO UPDATE SET content = excluded.content, updated_at = excluded.updated_at
      """, [.text(date), .text(content), .text(updatedAt)])
    return Note(date: date, content: content, updatedAt: updatedAt)
  }

  @discardableResult
  public func save(_ date: String, _ content: String, base: String? = nil) throws -> Note {
    guard Day.isKey(date) else { throw StoreError(message: "Invalid date") }
    try exec("BEGIN IMMEDIATE")
    do {
      var next = content
      if let base {
        let current = try get(date).content
        if current != base { next = Outline.merge(base: base, mine: content, theirs: current) }
      }
      let saved = try put(date, next)
      try exec("COMMIT")
      return saved
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  public func search(_ text: String) throws -> [Note] {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return [] }
    return try notes(
      """
      SELECT date, content, updated_at FROM notes
      WHERE instr(lower(content), lower(?)) > 0
      ORDER BY date DESC LIMIT 60
      """, [.text(normalized)])
  }

  public func notesBefore(_ date: String, limit: Int) throws -> [Note] {
    try notes(
      """
      SELECT date, content, updated_at FROM notes
      WHERE date < ? AND has_note_content(content) = 1
      ORDER BY date DESC LIMIT ?
      """, [.text(date), .int(limit)]
    ).reversed()
  }

  public func notesAfter(_ date: String, limit: Int) throws -> [Note] {
    try notes(
      """
      SELECT date, content, updated_at FROM notes
      WHERE date > ? AND has_note_content(content) = 1
      ORDER BY date ASC LIMIT ?
      """, [.text(date), .int(limit)])
  }

  public func dataVersion() throws -> Int {
    var version = 0
    try query("PRAGMA data_version") { version = self.int($0, 0) ?? 0 }
    return version
  }

  public func versions() throws -> [String: String] {
    var versions: [String: String] = [:]
    try query("SELECT date, updated_at FROM notes") { row in
      versions[self.text(row, 0) ?? ""] = self.text(row, 1) ?? ""
    }
    return versions
  }

  public func saveImage(data: Data, mimeType: String, fileName: String, width: Int?, height: Int?) throws -> String {
    guard !data.isEmpty else { throw StoreError(message: "Image is empty") }
    guard data.count <= NoteStore.maxImageBytes else { throw StoreError(message: "Image is larger than 15 MB") }
    guard NoteStore.imageTypes.contains(mimeType) else { throw StoreError(message: "Unsupported image type") }
    let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let name = String(
      fileName.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces).prefix(240))
    try query(
      """
      INSERT OR IGNORE INTO images (id, checksum, mime_type, file_name, width, height, byte_size, data, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        .text(id), .text(id), .text(mimeType), .text(name.isEmpty ? "Image" : name),
        width.map { .int($0) } ?? .null, height.map { .int($0) } ?? .null,
        .int(data.count), .blob(data), .text(timestamps.string(from: Date())),
      ])
    return id
  }

  public func image(_ id: String) throws -> StoredImage? {
    var image: StoredImage?
    try query("SELECT id, mime_type, file_name, width, height, data FROM images WHERE id = ?", [.text(id)]) { row in
      let bytes = sqlite3_column_blob(row, 5)
      let count = Int(sqlite3_column_bytes(row, 5))
      image = StoredImage(
        id: self.text(row, 0) ?? id, mimeType: self.text(row, 1) ?? "", fileName: self.text(row, 2) ?? "Image",
        width: self.int(row, 3), height: self.int(row, 4),
        data: bytes.map { Data(bytes: $0, count: count) } ?? Data())
    }
    return image
  }
}
