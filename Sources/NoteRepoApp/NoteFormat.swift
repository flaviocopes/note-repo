import AppKit
import NoteRepoCore

extension NSAttributedString.Key {
  static let noteDepth = NSAttributedString.Key("NoteRepoDepth")
  static let noteOrdered = NSAttributedString.Key("NoteRepoOrdered")
  static let noteStart = NSAttributedString.Key("NoteRepoStart")
  static let noteLinkToken = NSAttributedString.Key("NoteRepoLinkToken")
}

extension NSPasteboard.PasteboardType {
  static let noteMarkdown = NSPasteboard.PasteboardType("com.flaviocopes.noterepo.markdown")
}

struct ListStyle: Equatable {
  var depth = 0
  var ordered = false
  var start = 1
}

enum NoteFormat {
  static let font = Theme.mono(13)
  static let lineHeight: CGFloat = 22.1
  static let indent: CGFloat = 16.9
  static let listPadding: CGFloat = 14.95
  static let gutter: CGFloat = 28

  static var textHeight: CGFloat { font.ascender - font.descender }
  static var textBaseline: CGFloat { (lineHeight - textHeight) / 2 + font.ascender }

  private static var styles: [Int: NSParagraphStyle] = [:]

  static func paragraphStyle(_ depth: Int) -> NSParagraphStyle {
    if let style = styles[depth] { return style }
    let style = NSMutableParagraphStyle()
    style.firstLineHeadIndent = indent * CGFloat(depth + 1)
    style.headIndent = indent * CGFloat(depth + 1)
    style.lineBreakMode = .byWordWrapping
    styles[depth] = style
    return style
  }

  static func listAttributes(_ list: ListStyle) -> [NSAttributedString.Key: Any] {
    [
      .paragraphStyle: paragraphStyle(list.depth), .noteDepth: list.depth, .noteOrdered: list.ordered,
      .noteStart: list.start,
    ]
  }

  static func attributes(_ list: ListStyle) -> [NSAttributedString.Key: Any] {
    listAttributes(list).merging([.font: font, .foregroundColor: Theme.text]) { $1 }
  }

  static func listStyle(_ attributes: [NSAttributedString.Key: Any]) -> ListStyle {
    ListStyle(
      depth: attributes[.noteDepth] as? Int ?? 0, ordered: attributes[.noteOrdered] as? Bool ?? false,
      start: attributes[.noteStart] as? Int ?? 1)
  }

  static func paragraphRanges(_ string: String) -> [NSRange] {
    var ranges: [NSRange] = []
    var start = 0
    var index = 0
    for unit in string.utf16 {
      if unit == 10 {
        ranges.append(NSRange(location: start, length: index - start))
        start = index + 1
      }
      index += 1
    }
    ranges.append(NSRange(location: start, length: index - start))
    return ranges
  }

  struct Rendered {
    var text: NSAttributedString
    var trailingStyle: ListStyle?
  }

  static func render(_ content: String, store: NoteStore?) -> Rendered {
    let entries = Outline.parse(content)
    let result = NSMutableAttributedString()
    var runStarts: [Int?] = []
    var trailing: ListStyle?
    for (index, entry) in entries.enumerated() {
      if runStarts.count > entry.depth + 1 { runStarts.removeLast(runStarts.count - entry.depth - 1) }
      while runStarts.count < entry.depth + 1 { runStarts.append(nil) }
      var list = ListStyle(depth: entry.depth, ordered: entry.ordered, start: 1)
      if entry.ordered {
        list.start = runStarts[entry.depth] ?? entry.start
        runStarts[entry.depth] = list.start
      } else {
        runStarts[entry.depth] = nil
      }
      let attributes = attributes(list)
      result.append(body(entry.body, attributes: attributes, store: store))
      if index < entries.count - 1 {
        result.append(NSAttributedString(string: "\n", attributes: attributes))
      } else if entry.body.isEmpty {
        trailing = list
      }
    }
    return Rendered(text: result, trailingStyle: trailing)
  }

  static func body(_ body: String, attributes: [NSAttributedString.Key: Any], store: NoteStore?) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for token in Links.tokens(body) {
      switch token {
      case .text(let text):
        let plain = text.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "<br>", with: "\u{2028}")
        result.append(NSAttributedString(string: plain, attributes: attributes))
      case .link(let title, let url):
        var linkAttributes = attributes
        linkAttributes[.link] = url
        result.append(NSAttributedString(string: title ?? url, attributes: linkAttributes))
      case .image(let id, let alt):
        let image = NSMutableAttributedString(attachment: ImageAttachment(id: id, alt: alt, store: store))
        image.addAttributes(attributes, range: NSRange(location: 0, length: image.length))
        result.append(image)
      }
    }
    return result
  }

  static func inlineMarkdown(_ text: NSAttributedString, _ range: NSRange) -> String {
    var markdown = ""
    let source = text.string as NSString
    text.enumerateAttribute(.link, in: range) { value, run, _ in
      let label = source.substring(with: run)
      if let url = (value as? String) ?? (value as? URL)?.absoluteString {
        let clean = label.replacingOccurrences(of: "\u{fffc}", with: "")
        markdown += clean == url ? url : "[\(Links.cleanTitle(clean))](\(url))"
        return
      }
      text.enumerateAttribute(.attachment, in: run) { attachment, piece, _ in
        if let attachment = attachment as? NoteAttachment {
          markdown += attachment.markdown
        } else {
          markdown += source.substring(with: piece).replacingOccurrences(of: "\u{fffc}", with: "")
        }
      }
    }
    return markdown.replacingOccurrences(of: "\u{00a0}", with: " ").replacingOccurrences(of: "\u{2028}", with: "<br>")
  }

  static func entries(_ text: NSAttributedString, range: NSRange? = nil, trailingStyle: ListStyle?) -> [OutlineEntry] {
    let whole = NSRange(location: 0, length: text.length)
    let limit = range ?? whole
    var entries: [OutlineEntry] = []
    let ranges = paragraphRanges(text.string)
    for (index, paragraph) in ranges.enumerated() {
      let full = NSRange(location: paragraph.location, length: paragraph.length + (index < ranges.count - 1 ? 1 : 0))
      if range != nil && NSIntersectionRange(full, limit).length == 0
        && !(limit.length == 0 && NSLocationInRange(limit.location, full))
      {
        continue
      }
      let style: ListStyle
      if paragraph.length > 0 || index < ranges.count - 1 {
        style = listStyle(text.attributes(at: min(paragraph.location, text.length - 1), effectiveRange: nil))
      } else {
        style = trailingStyle ?? (text.length > 0 ? listStyle(text.attributes(at: text.length - 1, effectiveRange: nil)) : ListStyle())
      }
      let bodyRange = range == nil ? paragraph : NSIntersectionRange(paragraph, limit)
      entries.append(
        OutlineEntry(
          depth: style.depth, ordered: style.ordered, start: style.start, body: inlineMarkdown(text, bodyRange)))
    }
    return entries
  }

  static func markdown(_ text: NSAttributedString, trailingStyle: ListStyle?) -> String {
    Outline.normalized(entries(text, trailingStyle: trailingStyle))
  }

  static func cleanPasted(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{200b}", with: "").replacingOccurrences(of: "\u{feff}", with: "")
      .components(separatedBy: "\n")
      .map { line in
        var line = Substring(line)
        while let last = line.last, last.isWhitespace { line = line.dropLast() }
        return String(line)
      }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
