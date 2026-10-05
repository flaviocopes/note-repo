import CryptoKit
import Foundation
import NoteRepoCore

public struct CLIContext {
  public var arguments: [String]
  public var environment: [String: String]
  public var currentDirectory: String
  public var readStdin: () -> String
  public var runningApp: () -> String?
  public var open: ([String]) -> Bool

  public init(
    arguments: [String], environment: [String: String], currentDirectory: String, readStdin: @escaping () -> String,
    runningApp: @escaping () -> String?, open: @escaping ([String]) -> Bool
  ) {
    self.arguments = arguments
    self.environment = environment
    self.currentDirectory = currentDirectory
    self.readStdin = readStdin
    self.runningApp = runningApp
    self.open = open
  }
}

public struct CLIOutput {
  public var stdout = ""
  public var stderr = ""
  public var code: Int32 = 0
}

struct CLIError: Error {
  let message: String
  var code: Int32 = 1
}

private func usage(_ message: String) -> CLIError {
  CLIError(message: "\(message). Run \"noterepo help\" for the commands", code: 2)
}

public enum CLI {
  static let bundleID = "com.flaviocopes.noterepo"
  static let optionPattern = NSRegularExpression(#"^--([a-z-]+)(?:=([\s\S]*))?$"#)
  static let digits = NSRegularExpression(#"^\d+$"#)
  static let bareURL = NSRegularExpression(#"^https?://\S+$"#, .caseInsensitive)

  static let help = """
    noterepo \(NoteRepoVersion.current), the NoteRepo companion CLI for agents

    Every command prints JSON. Errors print {"error": "..."} to stderr and exit
    with 1, or 2 for a wrong command or option.

    A day is a list of items. Each item has a number (n), a level (0 for top
    level, 1 for nested under the item before it, and so on), a list type
    (bullet or numbered) and its text. A line break inside an item is <br> in
    its text. Commands that take N use the n shown by "show". Removing or
    moving an item takes its nested items with it.

    DATE is YYYY-MM-DD, "today" or "yesterday". NoteRepo has no future days, so
    commands that write only accept today and earlier days.

    Read
      info                            Data folder, database, app status and counts
      days [--from DATE] [--to DATE] [--limit N]
                                      Days with notes, newest first (limit 30, 0 for all)
      show [DATE]                     Every item of a day (default today)
      search QUERY                    Days and items containing QUERY
      title URL                       The link text NoteRepo shows for URL

    Write
      add TEXT [--date DATE] [--after N | --before N] [--level L] [--numbered | --bullet] [--raw]
                                      Add one item, at the end of the day by default.
                                      A URL on its own gets its page title, like pasting it.
                                      X posts stay as URLs so the app shows a preview.
      image FILE [--date DATE] [--after N | --before N] [--level L]
                                      Add a PNG, JPEG, GIF, WebP or SVG image
      edit N [TEXT] [--date DATE] [--level L] [--numbered | --bullet] [--raw]
                                      Change the text, level or list type of an item
      remove N... [--date DATE]       Delete items
      move N [--date DATE] [--to DATE] [--after M | --before M] [--level L]
                                      Move an item within a day or to another day
      write [DATE] [--content TEXT] [--append] [--raw]
                                      Replace a day with Markdown list lines from
                                      --content or stdin. --append adds them instead.
      write --json [--content JSON] [--append] [--raw]
                                      Write many days at once from an object like
                                      {"2026-09-28": "- Plan\\n  1. Write"} (strings or arrays of lines)
      clear DATE                      Delete everything written on a day

    App
      open [DATE]                     Bring NoteRepo to the front on a day

    Safety
      backup [--to DIR]               Save a copy of every note and image
      reset --yes                     Back up, then empty the notebook
      restore PATH --yes              Back up, then replace every note with a backup
                                      (a backup folder or a notes.sqlite3 file)

    Agent
      capabilities [--json]           Summary, tasks and release history for agents

    Options for every command
      --data-dir DIR                  Use another data folder (or NOTEREPO_DATA_DIR).
                                      Pair it with the app's --user-data-dir.
      --help, --version

    Changes show up in the running app within a second.
    """

  // MARK: Options

  enum Kind { case string, boolean }

  struct Parsed {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    subscript(_ name: String) -> String? { values[name] }
    func has(_ name: String) -> Bool { flags.contains(name) }
  }

  static let common: [String: Kind] = ["data-dir": .string, "help": .boolean]
  static let dateOption: [String: Kind] = ["date": .string]
  static let position: [String: Kind] = ["after": .string, "before": .string, "level": .string]
  static let list: [String: Kind] = ["numbered": .boolean, "bullet": .boolean]
  static let rawOption: [String: Kind] = ["raw": .boolean]

  static func options(_ sets: [String: Kind]...) -> [String: Kind] {
    sets.reduce(into: [:]) { result, set in result.merge(set) { $1 } }
  }

  static func parseOptions(_ args: [String], _ options: [String: Kind]) throws -> Parsed {
    var parsed = Parsed()
    var index = 0
    while index < args.count {
      let arg = args[index]
      if arg == "--" {
        parsed.positionals += args[(index + 1)...]
        break
      }
      guard let groups = optionPattern.groups(in: arg), let name = groups[1] else {
        parsed.positionals.append(arg)
        index += 1
        continue
      }
      let inline = groups[2]
      guard let kind = options[name] else { throw usage("Unknown option --\(name)") }
      if kind == .boolean {
        if inline != nil { throw usage("--\(name) doesn't take a value") }
        parsed.flags.insert(name)
        index += 1
        continue
      }
      guard let value = inline ?? (index + 1 < args.count ? args[index + 1] : nil) else {
        throw usage("--\(name) needs a value")
      }
      if inline == nil { index += 1 }
      parsed.values[name] = value
      index += 1
    }
    return parsed
  }

  // MARK: Values

  static func parseDate(_ value: String?, writing: Bool = false) throws -> String {
    let original = value ?? "today"
    var date = original
    if date == "today" { date = Day.today }
    if date == "yesterday" { date = Day.adding(-1, to: Day.today) }
    guard Day.isKey(date) else { throw usage("\"\(original)\" isn't a date. Use YYYY-MM-DD, today or yesterday") }
    if writing && date > Day.today {
      throw CLIError(message: "\(date) is in the future. NoteRepo only keeps notes for today and earlier days")
    }
    return date
  }

  static func parseNumber(_ value: String?, _ name: String, minimum: Int = 1) throws -> Int? {
    guard let value else { return nil }
    guard digits.matches(value), (Int(value) ?? .max) >= minimum else {
      throw usage("\(name) must be a whole number\(minimum > 0 ? " from 1" : ""), not \"\(value)\"")
    }
    return Int(value) ?? .max
  }

  static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

  static func isBareURL(_ value: String) -> Bool { bareURL.matches(value) }

  static func plainText(_ text: String) -> String {
    text.replacingOccurrences(
      of: #"!\[[^\]]*\]\(noterepo:image:[a-f0-9]{64}\)"#, with: "[Image]", options: [.regularExpression, .caseInsensitive]
    ).replacingOccurrences(
      of: #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#, with: "$1", options: [.regularExpression, .caseInsensitive])
  }

  static func cleanImageAlt(_ value: String) -> String {
    let clean = trim(value.replacingOccurrences(of: #"[\[\]\r\n]"#, with: " ", options: .regularExpression))
    return clean.isEmpty ? "Image" : String(clean.prefix(240))
  }

  // MARK: Output

  static func itemJSON(_ item: OutlineItem) -> JSON {
    let kind: String
    var extra: JSON = .object([:])
    switch item.kind {
    case .text: kind = "text"
    case .link(let links):
      kind = "link"
      extra = .object(["links": .array(links.map { .object(["title": .text($0.title), "url": .string($0.url)]) })])
    case .image(let id, let alt):
      kind = "image"
      extra = .object(["image": .object(["id": .string(id), "alt": .string(alt)])])
    case .post(let post):
      kind = "post"
      extra = .object(["post": .object(["url": .string(post.url), "user": .string(post.user), "id": .string(post.id)])])
    }
    return JSON.object([
      "n": .int(item.n), "level": .int(item.level), "list": .string(item.ordered ? "numbered" : "bullet"),
      "number": item.number.map(JSON.int), "kind": .string(kind), "text": .string(item.text),
    ]).merging(extra)
  }

  static func items(_ content: String) -> [OutlineItem] { Outline.describe(Outline.parse(content)) }

  static func dayOutput(_ store: NoteStore, _ date: String) throws -> JSON {
    let note = try store.get(date)
    return .object([
      "date": .string(date), "title": .string(Day.title(date)), "updatedAt": .text(note.updatedAt),
      "items": .array(items(note.content).map(itemJSON)), "content": .string(note.content),
    ])
  }

  static func statsJSON(_ store: NoteStore) throws -> JSON {
    let stats = try store.stats()
    return .object([
      "days": .int(stats.days), "firstDay": .text(stats.firstDay), "lastDay": .text(stats.lastDay),
      "images": .int(stats.images),
    ])
  }

  // MARK: Placing items

  final class Lines {
    var entries: [OutlineEntry]
    init(_ entries: [OutlineEntry]) { self.entries = entries }
  }

  struct Placement {
    var after: Int?
    var before: Int?
    var level: Int?
    var numbered = false
    var bullet = false
  }

  static func itemIndexes(_ entries: [OutlineEntry]) -> [Int] {
    entries.indices.filter { !trim(entries[$0].body).isEmpty }
  }

  static func findItem(_ entries: [OutlineEntry], _ n: Int) throws -> Int {
    let indexes = itemIndexes(entries)
    guard n >= 1, n <= indexes.count else {
      throw CLIError(
        message: "Item \(n) doesn't exist. This day has \(indexes.count) item\(indexes.count == 1 ? "" : "s")")
    }
    return indexes[n - 1]
  }

  static func placement(_ parsed: Parsed) throws -> Placement {
    if parsed.has("numbered") && parsed.has("bullet") { throw usage("Pass --numbered or --bullet, not both") }
    if parsed["after"] != nil && parsed["before"] != nil { throw usage("Pass --after or --before, not both") }
    return Placement(
      after: try parseNumber(parsed["after"], "--after"), before: try parseNumber(parsed["before"], "--before"),
      level: try parseNumber(parsed["level"], "--level", minimum: 0), numbered: parsed.has("numbered"),
      bullet: parsed.has("bullet"))
  }

  static func insertionPoint(_ entries: [OutlineEntry], _ options: Placement) throws -> (index: Int, level: Int) {
    if let after = options.after {
      let index = try findItem(entries, after)
      return (Outline.subtreeEnd(entries, index), entries[index].depth)
    }
    if let before = options.before {
      let index = try findItem(entries, before)
      return (index, entries[index].depth)
    }
    var index = entries.count
    while index > 0 && trim(entries[index - 1].body).isEmpty { index -= 1 }
    return (index, 0)
  }

  static func checkLevel(_ entries: [OutlineEntry], _ index: Int, _ level: Int) throws {
    let deepest = index == 0 ? 0 : entries[index - 1].depth + 1
    if level > deepest {
      throw CLIError(
        message: "Level \(level) is too deep there. The deepest level allowed at that position is \(deepest)")
    }
  }

  static func listType(_ entries: [OutlineEntry], _ index: Int, _ level: Int, _ options: Placement) -> Bool {
    if options.numbered { return true }
    if options.bullet { return false }
    var previous = index - 1
    while previous >= 0 && entries[previous].depth >= level {
      if entries[previous].depth == level { return entries[previous].ordered }
      previous -= 1
    }
    let next = index < entries.count ? entries[index] : nil
    return next?.depth == level && next?.ordered == true
  }

  static func place(_ lines: Lines, _ subtree: [OutlineEntry], _ options: Placement) throws {
    let point = try insertionPoint(lines.entries, options)
    let level = options.level ?? point.level
    try checkLevel(lines.entries, point.index, level)
    let root = subtree[0]
    let shift = level - root.depth
    for entry in subtree {
      entry.depth += shift
      entry.dirty = true
    }
    root.ordered = listType(lines.entries, point.index, level, options)
    let next = point.index < lines.entries.count ? lines.entries[point.index] : nil
    root.start = root.ordered && next?.ordered == true && next?.depth == level ? next!.start : 1
    lines.entries.insert(contentsOf: subtree, at: point.index)
  }

  static func detach(_ lines: Lines, _ index: Int) -> [OutlineEntry] {
    let end = Outline.subtreeEnd(lines.entries, index)
    let removed = Array(lines.entries[index..<end])
    lines.entries.removeSubrange(index..<end)
    if removed[0].ordered, index < lines.entries.count {
      let next = lines.entries[index]
      if next.ordered && next.depth == removed[0].depth && next.start != removed[0].start {
        next.start = removed[0].start
        next.dirty = true
      }
    }
    return removed
  }

  static func newItem(_ body: String) -> OutlineEntry { OutlineEntry(depth: 0, ordered: false, body: body) }

  // MARK: Text and titles

  static func titled(_ value: String, raw: Bool) async -> String {
    guard !raw, isBareURL(value), Links.tweet(value) == nil else { return value }
    guard let title = await LinkTitles.fetch(value) else { return value }
    return Links.linkText(url: value, title: title)
  }

  static func itemText(_ words: [String], raw: Bool, _ context: CLIContext) async throws -> (body: String, ordered: Bool) {
    let joined = words == ["-"] ? context.readStdin() : words.joined(separator: " ")
    let text = trim(Outline.cleanText(joined))
    if text.contains("\n") { throw usage("An item is one line. Use \"write --append\" to add several lines") }
    guard let entry = Outline.inputEntries(text).first else { throw usage("Pass the text of the item") }
    return (await titled(entry.body, raw: raw), entry.ordered)
  }

  static func withTitles(_ entries: [OutlineEntry], raw: Bool) async -> [OutlineEntry] {
    let pending = entries.filter { isBareURL($0.body) }
    for start in stride(from: 0, to: pending.count, by: 6) {
      let batch = Array(pending[start..<min(start + 6, pending.count)])
      let bodies = batch.map(\.body)
      let titledBodies = await withTaskGroup(of: (Int, String).self) { group in
        for (offset, body) in bodies.enumerated() {
          group.addTask { (offset, await titled(body, raw: raw)) }
        }
        var results = bodies
        for await (offset, body) in group { results[offset] = body }
        return results
      }
      for (entry, body) in zip(batch, titledBodies) { entry.body = body }
    }
    return entries
  }

  static func linesFrom(_ text: String, raw: Bool, _ label: String) async throws -> [OutlineEntry] {
    let entries = Outline.inputEntries(text)
    if entries.isEmpty { throw usage("Pass the lines \(label). To empty a day use \"clear\"") }
    return await withTitles(entries, raw: raw)
  }

  static func writeEntries(_ store: NoteStore, _ date: String, _ entries: [OutlineEntry], append: Bool) throws {
    let current = append ? Outline.parse(try store.get(date).content) : []
    let point = try insertionPoint(current, Placement())
    var previousDepth = point.index > 0 ? current[point.index - 1].depth : -1
    for entry in entries {
      entry.depth = min(entry.depth, previousDepth + 1)
      previousDepth = entry.depth
    }
    var merged = current
    merged.insert(contentsOf: entries, at: point.index)
    try store.put(date, Outline.serialize(merged))
  }

  // MARK: Files and backups

  static func resolve(_ path: String, _ context: CLIContext) -> String {
    let expanded = path.hasPrefix("~/") ? home(context) + path.dropFirst() : path
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: context.currentDirectory, isDirectory: true))
      .standardizedFileURL.path
  }

  static func home(_ context: CLIContext) -> String {
    context.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
  }

  static func sha256(_ path: String) throws -> String {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    return formatter.string(from: Date())
  }

  static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

  static func backup(_ store: NoteStore, _ dataDir: String, to: String? = nil, label: String? = nil, _ context: CLIContext)
    throws -> JSON
  {
    var folder: String
    if let to {
      folder = resolve(to, context)
    } else {
      let name = [timestamp(), label].compactMap { $0 }.joined(separator: "-")
      folder = (dataDir as NSString).appendingPathComponent("backups/\(name)")
      var copy = 2
      while exists(folder) {
        folder = (dataDir as NSString).appendingPathComponent("backups/\(name)-\(copy)")
        copy += 1
      }
    }
    let database = (folder as NSString).appendingPathComponent("notes.sqlite3")
    if exists(database) { throw CLIError(message: "\(database) already exists") }
    try store.backup(to: URL(fileURLWithPath: database))
    let stats = try store.stats()
    return .object([
      "path": .string(folder), "database": .string(database), "sha256": .string(try sha256(database)),
      "days": .int(stats.days), "images": .int(stats.images),
    ])
  }

  // MARK: Commands

  struct Command {
    var options: [String: Kind] = [:]
    var run: (NoteStore, String, Parsed, CLIContext) async throws -> JSON
  }

  static let commands: [String: Command] = [
    "info": Command { store, dataDir, _, context in
      let app = context.runningApp()
      return JSON.object([
        "version": .string(NoteRepoVersion.current), "dataDir": .string(dataDir), "database": .string(store.url.path),
        "backups": .string((dataDir as NSString).appendingPathComponent("backups")),
        "app": .object(["running": .bool(app != nil), "path": .text(app)]),
      ]).merging(try statsJSON(store))
    },

    "days": Command(options: ["from": .string, "to": .string, "limit": .string]) { store, _, parsed, _ in
      let limit = try parseNumber(parsed["limit"] ?? "30", "--limit", minimum: 0) ?? 30
      let days = try store.days(
        from: try parsed["from"].map { try parseDate($0) } ?? "0000-01-01",
        to: try parsed["to"].map { try parseDate($0) } ?? "9999-12-31",
        limit: limit == 0 ? -1 : limit)
      return .object([
        "days": .array(
          days.map { note in
            let list = items(note.content)
            return .object([
              "date": .string(note.date), "title": .string(Day.title(note.date)), "items": .int(list.count),
              "preview": .string(String(plainText(list.first?.text ?? "").prefix(100))),
            ])
          })
      ])
    },

    "show": Command { store, _, parsed, _ in try dayOutput(store, try parseDate(parsed.positionals.first)) },

    "search": Command { store, _, parsed, _ in
      let query = trim(parsed.positionals.joined(separator: " "))
      if query.isEmpty { throw usage("Pass something to search for") }
      let needle = query.lowercased()
      return .object([
        "query": .string(query),
        "results": .array(
          try store.search(query).map { note in
            .object([
              "date": .string(note.date), "title": .string(Day.title(note.date)),
              "items": .array(items(note.content).filter { $0.text.lowercased().contains(needle) }.map(itemJSON)),
            ])
          }),
      ])
    },

    "title": Command { _, _, parsed, _ in
      guard let url = parsed.positionals.first, isBareURL(url) else {
        throw usage("Pass a web link starting with http:// or https://")
      }
      if Links.tweet(url) != nil {
        return .object(["url": .string(url), "title": .null, "text": .string(url), "preview": .string("x-post")])
      }
      let title = await LinkTitles.fetch(url)
      return .object([
        "url": .string(url), "title": .text(title), "text": .string(title.map { Links.linkText(url: url, title: $0) } ?? url),
      ])
    },

    "add": Command(options: options(dateOption, position, list, rawOption)) {
      store, _, parsed, context in
      let date = try parseDate(parsed["date"], writing: true)
      var options = try placement(parsed)
      let text = try await itemText(parsed.positionals, raw: parsed.has("raw"), context)
      if text.ordered && !options.bullet { options.numbered = true }
      try store.transaction {
        let lines = Lines(Outline.parse(try store.get(date).content))
        try place(lines, [newItem(text.body)], options)
        try store.put(date, Outline.serialize(lines.entries))
      }
      return try dayOutput(store, date)
    },

    "image": Command(options: options(dateOption, position, list)) { store, _, parsed, context in
      let date = try parseDate(parsed["date"], writing: true)
      let options = try placement(parsed)
      guard let file = parsed.positionals.first else { throw usage("Pass the image file") }
      let path = resolve(file, context)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw CLIError(message: "\(file) isn't a file")
      }
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
      if size > NoteStore.maxImageBytes { throw CLIError(message: "\(file) is larger than 15 MB") }
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      guard let mimeType = ImageData.mimeType(data) else {
        throw CLIError(message: "\(file) isn't a PNG, JPEG, GIF, WebP or safe SVG image")
      }
      let alt = cleanImageAlt((file as NSString).lastPathComponent)
      try store.transaction {
        let id = try store.saveImage(data: data, mimeType: mimeType, fileName: alt, width: nil, height: nil)
        let lines = Lines(Outline.parse(try store.get(date).content))
        try place(lines, [newItem("![\(alt)](noterepo:image:\(id))")], options)
        try store.put(date, Outline.serialize(lines.entries))
      }
      return try dayOutput(store, date)
    },

    "edit": Command(options: options(dateOption, ["level": .string], list, rawOption)) {
      store, _, parsed, context in
      let date = try parseDate(parsed["date"], writing: true)
      let words = Array(parsed.positionals.dropFirst())
      guard let n = try parseNumber(parsed.positionals.first, "N") else {
        throw usage("Pass the number of the item to edit")
      }
      var options = try placement(parsed)
      if words.isEmpty && options.level == nil && !options.numbered && !options.bullet {
        throw usage("Pass new text, --level, --numbered or --bullet")
      }
      let text = words.isEmpty ? nil : try await itemText(words, raw: parsed.has("raw"), context)
      if text?.ordered == true && !options.bullet { options.numbered = true }
      try store.transaction {
        let entries = Outline.parse(try store.get(date).content)
        let index = try findItem(entries, n)
        let entry = entries[index]
        if let text { entry.body = text.body }
        if options.numbered || options.bullet {
          entry.ordered = options.numbered
          entry.start = 1
        }
        if let level = options.level {
          try checkLevel(entries, index, level)
          let shift = level - entry.depth
          for nested in entries[index..<Outline.subtreeEnd(entries, index)] {
            nested.depth += shift
            nested.dirty = true
          }
        }
        entry.dirty = true
        try store.put(date, Outline.serialize(entries))
      }
      return try dayOutput(store, date)
    },

    "remove": Command(options: dateOption) { store, _, parsed, _ in
      let date = try parseDate(parsed["date"], writing: true)
      if parsed.positionals.isEmpty { throw usage("Pass the numbers of the items to remove") }
      let numbers = try parsed.positionals.map { try parseNumber($0, "N")! }
      try store.transaction {
        let lines = Lines(Outline.parse(try store.get(date).content))
        let targets = try numbers.map { lines.entries[try findItem(lines.entries, $0)] }
        for target in targets {
          if let index = lines.entries.firstIndex(where: { $0 === target }) { _ = detach(lines, index) }
        }
        try store.put(date, Outline.serialize(lines.entries))
      }
      return try dayOutput(store, date)
    },

    "move": Command(options: options(dateOption, ["to": .string], position, list)) {
      store, _, parsed, _ in
      let date = try parseDate(parsed["date"], writing: true)
      let target = try parsed["to"].map { try parseDate($0, writing: true) } ?? date
      guard let n = try parseNumber(parsed.positionals.first, "N") else {
        throw usage("Pass the number of the item to move")
      }
      let options = try placement(parsed)
      try store.transaction {
        let source = Lines(Outline.parse(try store.get(date).content))
        let destination = target == date ? source : Lines(Outline.parse(try store.get(target).content))
        let moving = source.entries[try findItem(source.entries, n)]
        let reference = options.after ?? options.before
        let anchor = try reference.map { destination.entries[try findItem(destination.entries, $0)] }
        let subtree = detach(source, source.entries.firstIndex { $0 === moving }!)
        if let anchor, subtree.contains(where: { $0 === anchor }) {
          throw CLIError(message: "An item can't move inside itself")
        }
        var position = options
        let anchorNumber = anchor.flatMap { anchor in
          destination.entries.firstIndex { $0 === anchor }.flatMap { itemIndexes(destination.entries).firstIndex(of: $0) }
        }.map { $0 + 1 }
        if options.after != nil { position.after = anchorNumber }
        if options.before != nil { position.before = anchorNumber }
        try place(destination, subtree, position)
        try store.put(date, Outline.serialize(source.entries))
        if target != date { try store.put(target, Outline.serialize(destination.entries)) }
      }
      if target == date { return try dayOutput(store, date) }
      return .object(["from": try dayOutput(store, date), "to": try dayOutput(store, target)])
    },

    "write": Command(options: ["content": .string, "json": .boolean, "append": .boolean, "raw": .boolean]) {
      store, _, parsed, context in
      let text = parsed["content"] ?? context.readStdin()
      let raw = parsed.has("raw")
      let append = parsed.has("append")

      if parsed.has("json") {
        let shape = usage("--json needs an object like {\"2026-09-28\": \"- Plan\"}")
        guard let days = try? JSON.parse(text), case .members(let fields) = days else { throw shape }
        var prepared: [(date: String, entries: [OutlineEntry])] = []
        for field in fields {
          let lines: String
          switch field.value {
          case .string(let value): lines = value
          case .array(let values):
            lines = values.map { value in
              switch value {
              case .string(let text): return text
              case .null: return ""
              default: return value.compact
              }
            }.joined(separator: "\n")
          default: throw usage("The value for \(field.key) must be a string or an array of lines")
          }
          prepared.append(
            (try parseDate(field.key, writing: true), try await linesFrom(lines, raw: raw, "for \(field.key)")))
        }
        try store.transaction {
          for day in prepared { try writeEntries(store, day.date, day.entries, append: append) }
        }
        return .object([
          "days": .array(
            try prepared.map { day in
              .object([
                "date": .string(day.date), "title": .string(Day.title(day.date)),
                "items": .int(items(try store.get(day.date).content).count),
              ])
            })
        ])
      }

      let date = try parseDate(parsed.positionals.first, writing: true)
      let entries = try await linesFrom(text, raw: raw, "with --content or stdin")
      try store.transaction { try writeEntries(store, date, entries, append: append) }
      return try dayOutput(store, date)
    },

    "clear": Command { store, _, parsed, _ in
      guard let first = parsed.positionals.first else { throw usage("Pass the date to clear") }
      let date = try parseDate(first, writing: true)
      try store.put(date, "")
      return .object(["date": .string(date), "cleared": .bool(true)])
    },

    "open": Command { _, _, parsed, context in
      let date = try parsed.positionals.first.map { try parseDate($0) } ?? "today"
      if date != "today" && date > Day.today { throw CLIError(message: "\(date) is in the future") }
      let url = date == "today" ? "noterepo://today" : "noterepo://day/\(date)"
      let app = context.runningApp()
      guard context.open(app.map { ["-a", $0, url] } ?? ["-b", bundleID, url]) else {
        throw CLIError(message: "Could not open NoteRepo. Is it installed?")
      }
      return .object(["opened": .string(date == "today" ? Day.today : date), "app": .string(app ?? bundleID)])
    },

    "backup": Command(options: ["to": .string]) { store, dataDir, parsed, context in
      try backup(store, dataDir, to: parsed["to"], context)
    },

    "reset": Command(options: ["yes": .boolean]) { store, dataDir, parsed, context in
      guard parsed.has("yes") else {
        throw CLIError(message: "reset empties the notebook after backing it up. Run it again with --yes", code: 2)
      }
      let saved = try backup(store, dataDir, label: "before-reset", context)
      try store.clearAll()
      return JSON.object(["backup": saved]).merging(try statsJSON(store))
    },

    "restore": Command(options: ["yes": .boolean]) { store, dataDir, parsed, context in
      guard let source = parsed.positionals.first else { throw usage("Pass a backup folder or notes.sqlite3 file") }
      guard parsed.has("yes") else {
        throw CLIError(message: "restore replaces every note after backing them up. Run it again with --yes", code: 2)
      }
      var isDirectory: ObjCBool = false
      let found = FileManager.default.fileExists(atPath: resolve(source, context), isDirectory: &isDirectory)
      let database = found && isDirectory.boolValue ? (source as NSString).appendingPathComponent("notes.sqlite3") : source
      let resolved = resolve(database, context)
      var databaseIsFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: resolved, isDirectory: &databaseIsFolder), !databaseIsFolder.boolValue
      else { throw CLIError(message: "\(database) doesn't exist") }
      let saved = try backup(store, dataDir, label: "before-restore", context)
      do {
        try store.restore(from: URL(fileURLWithPath: resolved))
      } catch {
        throw CLIError(message: "\(database) isn't a NoteRepo database. Your notes are unchanged")
      }
      return .object([
        "restored": JSON.object(["database": .string(resolved)]).merging(try statsJSON(store)), "backup": saved,
      ])
    },
  ]

  // MARK: Running

  public static func run(_ context: CLIContext) async -> CLIOutput {
    var output = CLIOutput()
    do {
      let args = context.arguments
      var position = 0
      while position < args.count && args[position].hasPrefix("-") { position += args[position] == "--data-dir" ? 2 : 1 }
      let name = position < args.count ? args[position] : nil
      var rest = Array(args.prefix(position))
      if position + 1 < args.count { rest += args[(position + 1)...] }

      if args.contains("--version") || args.contains("-v") {
        output.stdout = "noterepo \(NoteRepoVersion.current)\n"
        return output
      }
      guard let name, name != "help", !args.contains("-h") else {
        output.stdout = "\(help)\n"
        return output
      }
      if name == "capabilities" {
        let parsed = try parseOptions(rest, options(common, ["json": .boolean]))
        if parsed.has("help") {
          output.stdout = "\(help)\n"
          return output
        }
        output.stdout = try Manifest.render(json: parsed.has("json")) + "\n"
        return output
      }
      guard let command = commands[name] else { throw usage("\"\(name)\" isn't a command") }
      let parsed = try parseOptions(rest, options(common, command.options))
      if parsed.has("help") {
        output.stdout = "\(help)\n"
        return output
      }

      let environmentDir = context.environment["NOTEREPO_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
      let dataDir = resolve(
        parsed["data-dir"] ?? environmentDir ?? "\(home(context))/Library/Application Support/NoteRepo", context)
      let store = try NoteStore(url: URL(fileURLWithPath: dataDir).appendingPathComponent("notes.sqlite3"))
      let result = try await command.run(store, dataDir, parsed, context)
      output.stdout = result.pretty + "\n"
    } catch let error as CLIError {
      output.stderr = JSON.object(["error": .string(error.message)]).compact + "\n"
      output.code = error.code
    } catch {
      output.stderr = JSON.object(["error": .string(error.localizedDescription)]).compact + "\n"
      output.code = 1
    }
    return output
  }
}
