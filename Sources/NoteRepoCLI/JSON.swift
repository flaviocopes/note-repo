import Foundation

public indirect enum JSON: Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case members([Field])

  public struct Field: Equatable {
    public let key: String
    public let value: JSON
  }

  /// Keys keep their order, and nil values are left out, like `undefined` in JSON.stringify.
  static func object(_ pairs: KeyValuePairs<String, JSON?>) -> JSON {
    .members(pairs.compactMap { key, value in value.map { Field(key: key, value: $0) } })
  }

  static func int(_ value: Int) -> JSON { .number(Double(value)) }
  static func text(_ value: String?) -> JSON { value.map(JSON.string) ?? .null }

  var fields: [Field] {
    if case .members(let fields) = self { return fields }
    return []
  }

  func merging(_ other: JSON) -> JSON { .members(fields + other.fields) }

  subscript(_ key: String) -> JSON? { fields.first { $0.key == key }?.value }

  subscript(_ index: Int) -> JSON? {
    guard case .array(let items) = self, items.indices.contains(index) else { return nil }
    return items[index]
  }

  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var int: Int? {
    if case .number(let value) = self { return Int(value) }
    return nil
  }

  var array: [JSON] {
    if case .array(let items) = self { return items }
    return []
  }

  // MARK: Writing

  public var pretty: String { render(indent: 0) }

  public var compact: String {
    switch self {
    case .array(let items): return "[" + items.map(\.compact).joined(separator: ",") + "]"
    case .members(let fields):
      return "{" + fields.map { JSON.quote($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
    default: return render(indent: 0)
    }
  }

  private func render(indent: Int) -> String {
    let pad = String(repeating: "  ", count: indent + 1)
    let close = String(repeating: "  ", count: indent)
    switch self {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .number(let value):
      return value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    case .string(let value): return JSON.quote(value)
    case .array(let items):
      if items.isEmpty { return "[]" }
      return "[\n" + items.map { pad + $0.render(indent: indent + 1) }.joined(separator: ",\n") + "\n\(close)]"
    case .members(let fields):
      if fields.isEmpty { return "{}" }
      let members = fields.map { pad + JSON.quote($0.key) + ": " + $0.value.render(indent: indent + 1) }
      return "{\n" + members.joined(separator: ",\n") + "\n\(close)}"
    }
  }

  static func quote(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": result += "\\\""
      case "\\": result += "\\\\"
      case "\u{08}": result += "\\b"
      case "\u{0C}": result += "\\f"
      case "\n": result += "\\n"
      case "\r": result += "\\r"
      case "\t": result += "\\t"
      default:
        if scalar.value < 0x20 {
          result += String(format: "\\u%04x", scalar.value)
        } else {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result + "\""
  }

  // MARK: Reading

  struct ParseError: Error {}

  static func parse(_ text: String) throws -> JSON {
    var parser = Parser(scalars: Array(text.unicodeScalars))
    let value = try parser.value()
    parser.skipWhitespace()
    guard parser.index == parser.scalars.count else { throw ParseError() }
    return value
  }

  struct Parser {
    let scalars: [Unicode.Scalar]
    var index = 0

    mutating func skipWhitespace() {
      while index < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index]) { index += 1 }
    }

    mutating func expect(_ literal: String) throws {
      for scalar in literal.unicodeScalars {
        guard index < scalars.count, scalars[index] == scalar else { throw ParseError() }
        index += 1
      }
    }

    mutating func value() throws -> JSON {
      skipWhitespace()
      guard index < scalars.count else { throw ParseError() }
      switch scalars[index] {
      case "{":
        index += 1
        var fields: [Field] = []
        skipWhitespace()
        if index < scalars.count, scalars[index] == "}" {
          index += 1
          return .members(fields)
        }
        while true {
          skipWhitespace()
          guard case .string(let key) = try value() else { throw ParseError() }
          skipWhitespace()
          try expect(":")
          let item = try value()
          if let existing = fields.firstIndex(where: { $0.key == key }) {
            fields[existing] = Field(key: key, value: item)
          } else {
            fields.append(Field(key: key, value: item))
          }
          skipWhitespace()
          guard index < scalars.count else { throw ParseError() }
          if scalars[index] == "," {
            index += 1
          } else if scalars[index] == "}" {
            index += 1
            return .members(fields)
          } else {
            throw ParseError()
          }
        }
      case "[":
        index += 1
        var items: [JSON] = []
        skipWhitespace()
        if index < scalars.count, scalars[index] == "]" {
          index += 1
          return .array(items)
        }
        while true {
          items.append(try value())
          skipWhitespace()
          guard index < scalars.count else { throw ParseError() }
          if scalars[index] == "," {
            index += 1
          } else if scalars[index] == "]" {
            index += 1
            return .array(items)
          } else {
            throw ParseError()
          }
        }
      case "\"":
        index += 1
        var result = String.UnicodeScalarView()
        while index < scalars.count {
          let scalar = scalars[index]
          index += 1
          if scalar == "\"" { return .string(String(result)) }
          guard scalar == "\\" else {
            guard scalar.value >= 0x20 else { throw ParseError() }
            result.append(scalar)
            continue
          }
          guard index < scalars.count else { throw ParseError() }
          let escape = scalars[index]
          index += 1
          switch escape {
          case "\"", "\\", "/": result.append(escape)
          case "b": result.append("\u{08}")
          case "f": result.append("\u{0C}")
          case "n": result.append("\n")
          case "r": result.append("\r")
          case "t": result.append("\t")
          case "u":
            var code = try hex()
            if (0xD800..<0xDC00).contains(code), index + 1 < scalars.count, scalars[index] == "\\",
              scalars[index + 1] == "u"
            {
              index += 2
              let low = try hex()
              code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            }
            result.append(Unicode.Scalar(code) ?? "\u{FFFD}")
          default: throw ParseError()
          }
        }
        throw ParseError()
      case "t":
        try expect("true")
        return .bool(true)
      case "f":
        try expect("false")
        return .bool(false)
      case "n":
        try expect("null")
        return .null
      default:
        let start = index
        while index < scalars.count, "+-0123456789.eE".unicodeScalars.contains(scalars[index]) { index += 1 }
        let text = String(String.UnicodeScalarView(scalars[start..<index]))
        guard let number = Double(text) else { throw ParseError() }
        return .number(number)
      }
    }

    mutating func hex() throws -> UInt32 {
      guard index + 4 <= scalars.count, let code = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16)
      else { throw ParseError() }
      index += 4
      return code
    }
  }
}
