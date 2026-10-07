import AppKit
import NoteRepoCore

class NoteAttachment: NSTextAttachment {
  var displaySize = CGSize(width: 1, height: NoteFormat.lineHeight)
  var markdown: String { "" }
  var verticalMargin: CGFloat { 0 }

  init() {
    super.init(data: nil, ofType: nil)
  }

  required init?(coder: NSCoder) { nil }

  static func availableWidth(_ container: NSTextContainer, _ index: Int) -> CGFloat {
    let storage = container.layoutManager?.textStorage
    let style =
      index < (storage?.length ?? 0)
      ? storage?.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle : nil
    return max(60, container.size.width - container.lineFragmentPadding * 2 - (style?.headIndent ?? 0))
  }
}

enum ImageCache {
  struct Entry {
    let image: NSImage?
    let pixelSize: CGSize
    let fileName: String
  }

  static var entries: [String: Entry] = [:]

  static func entry(_ id: String, store: NoteStore?) -> Entry {
    if let entry = entries[id] { return entry }
    guard let stored = try? store?.image(id) else {
      return Entry(image: nil, pixelSize: CGSize(width: 180, height: 44), fileName: "Image")
    }
    let image = NSImage(data: stored.data)
    var size = image?.size ?? .zero
    if let width = stored.width, let height = stored.height, width > 0, height > 0 {
      size = CGSize(width: width, height: height)
    } else if let rep = image?.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
      size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    let entry = Entry(image: image, pixelSize: size.width > 0 ? size : CGSize(width: 180, height: 44), fileName: stored.fileName)
    entries[id] = entry
    return entry
  }
}

final class ImageAttachment: NoteAttachment {
  let imageID: String
  let alt: String
  let entry: ImageCache.Entry

  init(id: String, alt: String, store: NoteStore?) {
    imageID = id
    self.alt = alt
    entry = ImageCache.entry(id, store: store)
    super.init()
    attachmentCell = ImageCell(owner: self)
  }

  required init?(coder: NSCoder) { nil }

  static func cleanAlt(_ value: String) -> String {
    let clean = value.replacingOccurrences(of: #"[\[\]\r\n]"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    return clean.isEmpty ? "Image" : String(clean.prefix(240))
  }

  override var markdown: String { "![\(ImageAttachment.cleanAlt(alt))](noterepo:image:\(imageID))" }
  override var verticalMargin: CGFloat { 8 }

  func fittedSize(available: CGFloat) -> CGSize {
    let size = entry.pixelSize
    let scale = min(1, min(680, available) / size.width, 680 / size.height)
    return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
  }
}

final class ImageCell: NSTextAttachmentCell {
  weak var owner: ImageAttachment?

  init(owner: ImageAttachment) {
    self.owner = owner
    super.init(imageCell: nil)
  }

  required init(coder: NSCoder) { fatalError() }

  override func cellFrame(
    for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint,
    characterIndex charIndex: Int
  ) -> NSRect {
    guard let owner else { return .zero }
    owner.displaySize = owner.fittedSize(available: NoteAttachment.availableWidth(textContainer, charIndex))
    return NSRect(origin: .zero, size: owner.displaySize)
  }

  override func cellSize() -> NSSize { owner?.displaySize ?? .zero }
  override func cellBaselineOffset() -> NSPoint { .zero }
  override func wantsToTrackMouse() -> Bool { true }

  override func trackMouse(
    with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int,
    untilMouseUp flag: Bool
  ) -> Bool {
    guard let textView = controlView as? NoteTextView else { return false }
    textView.window?.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: charIndex, length: 1))
    guard let window = textView.window else { return true }
    let start = theEvent.locationInWindow
    while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if event.type == .leftMouseUp { break }
      if hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 {
        _ = textView.dragSelection(with: theEvent, offset: .zero, slideBack: true)
        break
      }
    }
    return true
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    draw(cellFrame, selected: false)
  }

  override func draw(
    withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
    layoutManager: NSLayoutManager
  ) {
    let selection = (controlView as? NSTextView)?.selectedRange() ?? NSRange(location: 0, length: 0)
    draw(cellFrame, selected: selection.length > 0 && NSLocationInRange(charIndex, selection))
  }

  private func draw(_ frame: NSRect, selected: Bool) {
    guard let owner else { return }
    let rect = frame.insetBy(dx: 0.5, dy: 0.5)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    if let image = owner.entry.image {
      NSGraphicsContext.saveGraphicsState()
      shape.addClip()
      image.draw(
        in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high.rawValue])
      NSGraphicsContext.restoreGraphicsState()
    } else {
      Theme.field.setFill()
      shape.fill()
      let label = NSAttributedString(
        string: ImageAttachment.cleanAlt(owner.alt),
        attributes: [.font: Theme.mono(11), .foregroundColor: Theme.muted])
      label.draw(at: NSPoint(x: frame.minX + 12, y: frame.midY - label.size().height / 2))
    }
    (selected ? Theme.accent : Theme.divider).setStroke()
    shape.lineWidth = 1
    shape.stroke()
    if selected {
      let ring = NSBezierPath(roundedRect: frame.insetBy(dx: -1, dy: -1), xRadius: 7, yRadius: 7)
      ring.lineWidth = 2
      Theme.accentGlow.setStroke()
      ring.stroke()
    }
  }
}
