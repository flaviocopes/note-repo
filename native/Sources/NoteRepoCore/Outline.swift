import Foundation

public struct OutlineEntry: Equatable, Sendable {
  public var depth: Int
  public var ordered: Bool
  public var start: Int
  public var body: String

  public init(depth: Int, ordered: Bool, start: Int = 1, body: String) {
    self.depth = depth
    self.ordered = ordered
    self.start = start
    self.body = body
  }
}

public enum Outline {
  static let maxMergeCells = 4_000_000

  public static func lines(_ content: String) -> [String] {
    content.components(separatedBy: "\n")
  }

  public static func parseLine(_ line: String, previousDepth: Int) -> OutlineEntry {
    var spaces = 0
    var tabs = 0
    var rest = Substring(line)
    while let first = rest.first, first == " " || first == "\t" {
      if first == "\t" { tabs += 1 } else { spaces += 1 }
      rest = rest.dropFirst()
    }
    let depth = min(tabs + spaces / 2, previousDepth + 1)

    let digits = rest.prefix(while: { ("0"..."9").contains($0) })
    if !digits.isEmpty {
      let afterDigits = rest.dropFirst(digits.count)
      if afterDigits.first == "." {
        let tail = afterDigits.dropFirst()
        if tail.isEmpty || tail.first!.isWhitespace {
          let body = String(tail.drop(while: { $0.isWhitespace }))
          return OutlineEntry(depth: depth, ordered: true, start: Int(digits) ?? 1, body: body)
        }
      }
    }

    if rest.first == "-" {
      var body = rest.dropFirst()
      if let first = body.first, first.isWhitespace { body = body.dropFirst() }
      return OutlineEntry(depth: depth, ordered: false, body: String(body))
    }
    return OutlineEntry(depth: depth, ordered: false, body: String(rest))
  }

  public static func parse(_ content: String) -> [OutlineEntry] {
    var entries: [OutlineEntry] = []
    for line in lines(content) {
      entries.append(parseLine(line, previousDepth: entries.last?.depth ?? -1))
    }
    return entries
  }

  public static func format(_ entry: OutlineEntry) -> String {
    let indent = String(repeating: "  ", count: entry.depth)
    let marker = entry.ordered ? "\(entry.start)." : "-"
    if !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return trimEnd("\(indent)\(marker) \(entry.body)")
    }
    return entry.depth > 0 ? "\(indent)\(marker)" : ""
  }

  public static func renumber(_ entries: [OutlineEntry]) -> [OutlineEntry] {
    var next: [Int?] = []
    return entries.map { entry in
      var entry = entry
      if next.count > entry.depth + 1 { next.removeLast(next.count - entry.depth - 1) }
      while next.count < entry.depth + 1 { next.append(nil) }
      guard entry.ordered else {
        next[entry.depth] = nil
        return entry
      }
      if let expected = next[entry.depth] { entry.start = expected }
      next[entry.depth] = entry.start + 1
      return entry
    }
  }

  public static func serialize(_ entries: [OutlineEntry]) -> String {
    renumber(entries).map(format).joined(separator: "\n")
  }

  public static func hasContent(_ content: String) -> Bool {
    lines(content).contains { line in
      let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
      return !value.isEmpty && !isBareMarker(value)
    }
  }

  static func isBareMarker(_ value: String) -> Bool {
    if value == "-" { return true }
    guard value.count > 1, value.hasSuffix(".") else { return false }
    return value.dropLast().allSatisfy { ("0"..."9").contains($0) }
  }

  static func trimEnd(_ value: String) -> String {
    var result = Substring(value)
    while let last = result.last, last.isWhitespace { result = result.dropLast() }
    return String(result)
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
