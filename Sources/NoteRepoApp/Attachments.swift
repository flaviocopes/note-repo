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
  static let minimumWidth: CGFloat = 64

  let imageID: String
  let alt: String
  var savedWidth: Int?
  let entry: ImageCache.Entry
  var displayWidth: CGFloat?

  init(id: String, alt: String, width: Int?, store: NoteStore?) {
    imageID = id
    self.alt = alt
    savedWidth = width
    displayWidth = width.map { CGFloat($0) }
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

  override var markdown: String { Links.imageMarkdown(alt: ImageAttachment.cleanAlt(alt), id: imageID, width: savedWidth) }
  override var verticalMargin: CGFloat { 8 }

  func fittedSize(available: CGFloat) -> CGSize { size(available: available, width: displayWidth) }

  /// `width` is the chosen display width. Nil keeps the image fitted to the column, never larger than its pixels.
  func size(available: CGFloat, width: CGFloat?) -> CGSize {
    let pixels = entry.pixelSize
    let safeWidth = max(pixels.width, 1)
    let safeHeight = max(pixels.height, 1)
    let fitted = min(1, min(680, available) / safeWidth, 680 / safeHeight)
    let natural = CGSize(width: max(1, (pixels.width * fitted).rounded()), height: max(1, (pixels.height * fitted).rounded()))
    guard let width else { return natural }
    let chosen = min(max(width.rounded(), Self.minimumWidth), max(available.rounded(), Self.minimumWidth))
    return CGSize(width: chosen, height: max(1, (chosen * safeHeight / safeWidth).rounded()))
  }
}

enum ImageResizeAxis {
  case horizontal
  case vertical
  case either

  var cursor: NSCursor {
    switch self {
    case .horizontal, .either: return .resizeLeftRight
    case .vertical: return .resizeUpDown
    }
  }

  func delta(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
    switch self {
    case .horizontal: return dx
    case .vertical: return dy
    case .either: return abs(dx) >= abs(dy) ? dx : dy
    }
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

  /// The circle drawn at the corner.
  static func handleRect(in frame: NSRect) -> NSRect {
    let side = min(22, frame.width, frame.height)
    return NSRect(x: frame.maxX - side, y: frame.maxY - side, width: side, height: side)
  }

  static func handleHitRect(in frame: NSRect) -> NSRect {
    let knob = handleRect(in: frame)
    let side: CGFloat = 44
    return NSRect(x: knob.midX - side / 2, y: knob.midY - side / 2, width: side, height: side)
  }

  /// How close the pointer has to be to the right or bottom line. A few points sit outside the image.
  static let edgeGrab: CGFloat = 16
  static let edgeSlack: CGFloat = 10

  /// `horizontal` is the right line, `vertical` is the bottom line, `either` is the corner.
  static func resizeAxis(in frame: NSRect, at point: NSPoint) -> ImageResizeAxis? {
    let onRight = point.x >= frame.maxX - edgeGrab && point.x <= frame.maxX + edgeSlack
      && point.y >= frame.minY - edgeSlack && point.y <= frame.maxY + edgeSlack
    let onBottom = point.y >= frame.maxY - edgeGrab && point.y <= frame.maxY + edgeSlack
      && point.x >= frame.minX - edgeSlack && point.x <= frame.maxX + edgeSlack
    if handleHitRect(in: frame).contains(point) || (onRight && onBottom) { return .either }
    if onRight { return .horizontal }
    if onBottom { return .vertical }
    return nil
  }

  static func rightCursorRect(in frame: NSRect) -> NSRect {
    NSRect(
      x: frame.maxX - edgeGrab, y: frame.minY - edgeSlack, width: edgeGrab + edgeSlack,
      height: frame.height + edgeSlack * 2)
  }

  static func bottomCursorRect(in frame: NSRect) -> NSRect {
    NSRect(
      x: frame.minX - edgeSlack, y: frame.maxY - edgeGrab, width: frame.width + edgeSlack * 2,
      height: edgeGrab + edgeSlack)
  }

  /// The rectangle the image is drawn in, in the text view's coordinates. The frame AppKit passes to
  /// tracking can sit away from that, so the corner handle is hit-tested against this one.
  static func drawnFrame(in textView: NSTextView, character: Int) -> NSRect? {
    guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer,
      let storage = textView.textStorage, character < storage.length
    else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    let glyph = layoutManager.glyphIndexForCharacter(at: character)
    var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
    rect.origin.x += textView.textContainerOrigin.x
    rect.origin.y += textView.textContainerOrigin.y
    return rect.isEmpty ? nil : rect
  }

  override func trackMouse(
    with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int,
    untilMouseUp flag: Bool
  ) -> Bool {
    guard let textView = controlView as? NoteTextView, let owner else { return false }
    textView.window?.makeFirstResponder(textView)
    let point = textView.convert(theEvent.locationInWindow, from: nil)
    textView.setSelectedRange(NSRange(location: charIndex, length: 1))
    let drawn = Self.drawnFrame(in: textView, character: charIndex) ?? cellFrame
    if textView.isEditable, let axis = Self.resizeAxis(in: drawn, at: point) {
      resize(from: theEvent, index: charIndex, textView: textView, owner: owner, axis: axis)
      return true
    }
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

  private func resize(
    from startEvent: NSEvent, index: Int, textView: NoteTextView, owner: ImageAttachment, axis: ImageResizeAxis
  ) {
    guard let window = textView.window, let container = textView.textContainer else { return }
    let start = textView.convert(startEvent.locationInWindow, from: nil)
    let startWidth = owner.displaySize.width
    var dragged = false
    axis.cursor.push()
    defer { NSCursor.pop() }
    while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if event.type == .leftMouseUp { break }
      let point = textView.convert(event.locationInWindow, from: nil)
      let delta = axis.delta(point.x - start.x, point.y - start.y)
      guard abs(delta) > 1 || dragged else { continue }
      dragged = true
      owner.displayWidth = startWidth + delta
      owner.displaySize = owner.fittedSize(available: NoteAttachment.availableWidth(container, index))
      textView.relayoutImage(at: index)
    }
    if dragged { textView.commitImageSize(at: index) }
  }

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
    draw(cellFrame, selected: false)
  }

  override func draw(
    withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int,
    layoutManager: NSLayoutManager
  ) {
    let textView = controlView as? NoteTextView
    let selection = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
    let selected = selection.length > 0 && NSLocationInRange(charIndex, selection)
    let hovered = textView?.hoveredImage == charIndex
    draw(cellFrame, selected: selected, showHandle: textView?.isEditable == true && (selected || hovered))
  }

  private func draw(_ frame: NSRect, selected: Bool, showHandle: Bool = false) {
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
    if showHandle { drawHandle(in: frame) }
  }

  private func drawHandle(in frame: NSRect) {
    let knob = NSBezierPath(ovalIn: Self.handleRect(in: frame).insetBy(dx: 5, dy: 5))
    Theme.popover.setFill()
    knob.fill()
    Theme.accent.setStroke()
    knob.lineWidth = 1.5
    knob.stroke()
  }
}
