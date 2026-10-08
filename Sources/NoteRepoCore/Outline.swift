import Foundation

public final class OutlineEntry: Equatable {
  public var depth: Int
  public var ordered: Bool
  public var start: Int
  public var body: String
  public var raw: String
  public var dirty: Bool

  public init(depth: Int, ordered: Bool, start: Int = 1, body: String, raw: String = "", dirty: Bool = true) {
    self.depth = depth
    self.ordered = ordered
    self.start = start
    self.body = body
    self.raw = raw
    self.dirty = dirty
  }

  public static func == (a: OutlineEntry, b: OutlineEntry) -> Bool {
    a.depth == b.depth && a.ordered == b.ordered && a.start == b.start && a.body == b.body
  }
}

public struct OutlineItem {
  public enum Kind {
    case text
    case link([(title: String?, url: String)])
    case image(id: String, alt: String)
  }

  public let n: Int
  public let level: Int
  public let ordered: Bool
  public let number: Int?
  public let text: String
  public let starred: Bool
  public let kind: Kind
}

public enum Outline {
  static let maxMergeCells = 4_000_000
  static let itemLink = NSRegularExpression(
    #"\[([^\]]+)\]\((https?://[^\s)]+)\)|(https?://[^\s<>()\]]+)"#, .caseInsensitive)
  static let orderedInput = NSRegularExpression(#"^(\d+)[.)](?:\s+|$)(.*)$"#)
  static let bulletInput = NSRegularExpression(#"^[-*+](?:\s+|$)(.*)$"#)

  public static func lines(_ content: String) -> [String] {
    content.components(separatedBy: "\n")
  }

  static func isDigit(_ character: Character) -> Bool { ("0"..."9").contains(character) }

  static func trim(_ value: some StringProtocol) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func indentation(_ line: String) -> (spaces: Int, tabs: Int, rest: Substring) {
    var spaces = 0
    var tabs = 0
    var rest = Substring(line)
    while let first = rest.first, first == " " || first == "\t" {
      if first == "\t" { tabs += 1 } else { spaces += 1 }
      rest = rest.dropFirst()
    }
    return (spaces, tabs, rest)
  }

  public static func parseLine(_ line: String, previousDepth: Int) -> OutlineEntry {
    let (spaces, tabs, rest) = indentation(line)
    let depth = min(tabs + spaces / 2, previousDepth + 1)
    let entry = { (ordered: Bool, start: Int, body: String) in
      OutlineEntry(depth: depth, ordered: ordered, start: start, body: body, raw: line, dirty: false)
    }

    let digits = rest.prefix(while: isDigit)
    if !digits.isEmpty {
      let afterDigits = rest.dropFirst(digits.count)
      if afterDigits.first == "." {
        let tail = afterDigits.dropFirst()
        if tail.isEmpty || tail.first!.isWhitespace {
          return entry(true, Int(digits) ?? 1, String(tail.drop(while: { $0.isWhitespace })))
        }
      }
    }

    if rest.first == "-" {
      var body = rest.dropFirst()
      if let first = body.first, first.isWhitespace { body = body.dropFirst() }
      return entry(false, 1, String(body))
    }
    return entry(false, 1, String(rest))
  }

  public static func parse(_ content: String) -> [OutlineEntry] {
    var entries: [OutlineEntry] = []
    for line in lines(content) {
      entries.append(parseLine(line, previousDepth: entries.last?.depth ?? -1))
    }
    return entries.count == 1 && entries[0].raw.isEmpty ? [] : entries
  }

  /// A star is `★` at the start of the line's text, with a space when the item has more text.
  public static func splitStar(_ body: String) -> (starred: Bool, text: String) {
    if body == "★" { return (true, "") }
    if body.hasPrefix("★ ") { return (true, String(body.dropFirst(2))) }
    return (false, body)
  }

  public static func withStar(_ text: String, starred: Bool) -> String {
    guard starred else { return text }
    return text.isEmpty ? "★" : "★ \(text)"
  }

  public static func format(_ entry: OutlineEntry) -> String {
    let indent = String(repeating: "  ", count: entry.depth)
    let marker = entry.ordered ? "\(entry.start)." : "-"
    if !trim(entry.body).isEmpty { return trimEnd("\(indent)\(marker) \(entry.body)") }
    return entry.depth > 0 ? "\(indent)\(marker)" : ""
  }

  @discardableResult
  public static func renumber(_ entries: [OutlineEntry]) -> [OutlineEntry] {
    var next: [Int?] = []
    for entry in entries {
      if next.count > entry.depth + 1 { next.removeLast(next.count - entry.depth - 1) }
      while next.count < entry.depth + 1 { next.append(nil) }
      guard entry.ordered else {
        next[entry.depth] = nil
        continue
      }
      if let expected = next[entry.depth], entry.start != expected {
        entry.start = expected
        entry.dirty = true
      }
      next[entry.depth] = entry.start + 1
    }
    return entries
  }

  /// Keeps every line nobody touched exactly as it was saved.
  public static func serialize(_ entries: [OutlineEntry]) -> String {
    renumber(entries).map { $0.dirty ? format($0) : $0.raw }.joined(separator: "\n")
  }

  /// Formats every line, the way the editor saves a day.
  public static func normalized(_ entries: [OutlineEntry]) -> String {
    renumber(entries).map(format).joined(separator: "\n")
  }

  public static func subtreeEnd(_ entries: [OutlineEntry], _ index: Int) -> Int {
    var end = index + 1
    while end < entries.count && entries[end].depth > entries[index].depth { end += 1 }
    return end
  }

  static func itemLinks(_ text: String) -> [(title: String?, url: String)] {
    let source = text as NSString
    return itemLink.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
      let group = { (index: Int) -> String? in
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : source.substring(with: range)
      }
      return (group(1), group(2) ?? Links.trimTrailingPunctuation(group(3) ?? ""))
    }
  }

  public static func describe(_ entries: [OutlineEntry]) -> [OutlineItem] {
    var n = 0
    return renumber(entries).compactMap { entry in
      let split = splitStar(trim(entry.body))
      let text = split.text
      guard !text.isEmpty else { return nil }
      n += 1
      let kind: OutlineItem.Kind
      if let image = Links.imageItem(text) {
        kind = .image(id: image.id, alt: image.alt)
      } else {
        let links = itemLinks(text)
        kind = links.isEmpty ? .text : .link(links)
      }
      return OutlineItem(
        n: n, level: entry.depth, ordered: entry.ordered, number: entry.ordered ? entry.start : nil, text: text,
        starred: split.starred, kind: kind)
    }
  }

  public static func hasContent(_ content: String) -> Bool {
    lines(content).contains { line in
      let value = trim(line)
      return !value.isEmpty && !isBareMarker(value)
    }
  }

  static func isBareMarker(_ value: String) -> Bool {
    if value == "-" { return true }
    guard value.count > 1, value.hasSuffix(".") else { return false }
    return value.dropLast().allSatisfy(isDigit)
  }

  static func trimEnd(_ value: String) -> String {
    var result = Substring(value)
    while let last = result.last, last.isWhitespace { result = result.dropLast() }
    return String(result)
  }

  public static func cleanText(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{200b}", with: "").replacingOccurrences(of: "\u{feff}", with: "")
      .components(separatedBy: "\n")
      .map { line in
        var line = Substring(line)
        while let last = line.last, last.isWhitespace, last != "\n" { line = line.dropLast() }
        return String(line)
      }
      .joined(separator: "\n")
  }

  public static func parseInputLine(_ line: String) -> (level: Int, ordered: Bool, body: String) {
    let (spaces, tabs, rest) = indentation(line)
    let level = tabs + spaces / 2
    let text = String(rest)
    if let groups = orderedInput.groups(in: text) { return (level, true, trim(groups[2] ?? "")) }
    if let groups = bulletInput.groups(in: text) { return (level, false, trim(groups[1] ?? "")) }
    return (level, false, trim(text))
  }

  /// Turns Markdown written by agents into Note Repo lines, ready to insert.
  public static func inputEntries(_ text: String) -> [OutlineEntry] {
    lines(cleanText(text)).compactMap { line in
      let parsed = parseInputLine(line)
      guard !parsed.body.isEmpty else { return nil }
      return OutlineEntry(depth: parsed.level, ordered: parsed.ordered, body: parsed.body)
    }
  }

  static func matchLines(_ a: [String], _ b: [String]) -> [(Int, Int)] {
    let width = b.count + 1
    var table = [UInt32](repeating: 0, count: (a.count + 1) * width)
    if !a.isEmpty && !b.isEmpty {
      for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
          table[i * width + j] =
            a[i] == b[j]
            ? table[(i + 1) * width + j + 1] + 1
            : max(table[(i + 1) * width + j], table[i * width + j + 1])
        }
      }
    }
    var pairs: [(Int, Int)] = []
    var i = 0
    var j = 0
    while i < a.count && j < b.count {
      if a[i] == b[j] {
        pairs.append((i, j))
        i += 1
        j += 1
      } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
    return pairs
  }

  public static func merge(base: String, mine: String, theirs: String) -> String {
    if mine == base || mine == theirs { return theirs }
    if theirs == base { return mine }

    let baseLines = lines(base)
    let mineLines = lines(mine)
    let theirLines = lines(theirs)
    if (baseLines.count + 1) * (mineLines.count + 1) > maxMergeCells
      || (baseLines.count + 1) * (theirLines.count + 1) > maxMergeCells
    {
      let added = theirLines.filter { !$0.isEmpty && !baseLines.contains($0) && !mineLines.contains($0) }
      return (mineLines + added).joined(separator: "\n")
    }

    let inMine = Dictionary(matchLines(baseLines, mineLines), uniquingKeysWith: { first, _ in first })
    let mineIndexFrom = { (baseIndex: Int) -> Int in
      var index = baseIndex
      while index < baseLines.count {
        if let match = inMine[index] { return match }
        index += 1
      }
      return mineLines.count
    }

    var removed = Set<Int>()
    var inserted: [Int: [String]] = [:]
    var baseIndex = 0
    var theirIndex = 0
    for (nextBase, nextTheirs) in matchLines(baseLines, theirLines) + [(baseLines.count, theirLines.count)] {
      let deleted = Array(baseIndex..<nextBase)
      var added = Array(theirLines[theirIndex..<nextTheirs])

      if !deleted.isEmpty || !added.isEmpty {
        if deleted.allSatisfy({ inMine[$0] != nil }) {
          deleted.forEach { removed.insert(inMine[$0]!) }
        } else {
          added = added.filter { !mineLines.contains($0) }
        }
        inserted[mineIndexFrom(nextBase), default: []] += added
      }
      baseIndex = nextBase + 1
      theirIndex = nextTheirs + 1
    }

    var merged: [String] = []
    for (index, line) in mineLines.enumerated() {
      merged += inserted[index] ?? []
      if !removed.contains(index) { merged.append(line) }
    }
    merged += inserted[mineLines.count] ?? []
    return merged.joined(separator: "\n")
  }
}
