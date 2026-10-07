import AppKit
import NoteRepoCore

protocol NoteTextViewOwner: AnyObject {
  var store: NoteStore { get }
  func textChanged()
  func textFocused()
  func textLayoutChanged()
  func textEndedEditing()
}

final class NoteLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
  override init() {
    super.init()
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  func layoutManager(
    _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
    lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
    in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
  ) -> Bool {
    var height = NoteFormat.lineHeight
    var baseline = NoteFormat.textBaseline
    if let storage = textStorage, glyphRange.length > 0 {
      let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
      storage.enumerateAttribute(.attachment, in: characters) { value, _, _ in
        guard let attachment = value as? NoteAttachment else { return }
        height = max(height, attachment.displaySize.height + attachment.verticalMargin * 2)
        baseline = max(baseline, attachment.verticalMargin + attachment.displaySize.height)
      }
    }
    lineFragmentRect.pointee.size.height = height
    lineFragmentUsedRect.pointee.size.height = height
    baselineOffset.pointee = baseline
    return true
  }

  // The delegate isn't asked about the empty line after a trailing newline, so give it a full line's height here.
  override func setExtraLineFragmentRect(
    _ fragmentRect: NSRect, usedRect: NSRect, textContainer container: NSTextContainer
  ) {
    var fragment = fragmentRect
    var used = usedRect
    fragment.size.height = NoteFormat.lineHeight
    used.size.height = NoteFormat.lineHeight
    super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: container)
  }

  override func drawUnderline(
    forGlyphRange glyphRange: NSRange, underlineType underlineVal: NSUnderlineStyle, baselineOffset: CGFloat,
    lineFragmentRect lineRect: NSRect, lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: NSPoint
  ) {
    guard let container = textContainer(forGlyphAt: glyphRange.location, effectiveRange: nil) else { return }
    let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
    let baseline = lineRect.minY + location(forGlyphAt: glyphRange.location).y
    Theme.linkUnderline.setFill()
    NSRect(
      x: containerOrigin.x + bounds.minX, y: containerOrigin.y + baseline + 3.5, width: bounds.width, height: 1
    ).fill()
  }
}

final class NoteTextView: NSTextView, NSTextViewDelegate {
  struct Paragraph {
    var range: NSRange
    var style: ListStyle
    var number: Int
    var attachment: NoteAttachment?
  }

  weak var owner: NoteTextViewOwner?
  var trailingStyle: ListStyle?
  private(set) var paragraphs: [Paragraph] = []
  private var paragraphStarts: [Int: Int] = [:]
  private var hoveredMarker: Int?
  private var markerTracking: NSTrackingArea?

  static func make() -> NoteTextView {
    let storage = NSTextStorage()
    let layout = NoteLayoutManager()
    storage.addLayoutManager(layout)
    let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40), textContainer: container)
    view.configure()
    return view
  }

  private func configure() {
    delegate = self
    drawsBackground = false
    isRichText = true
    importsGraphics = false
    allowsUndo = true
    usesFontPanel = false
    usesFindPanel = false
    usesRuler = false
    focusRingType = .none
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    isAutomaticLinkDetectionEnabled = false
    isAutomaticDataDetectionEnabled = false
    isAutomaticTextCompletionEnabled = false
    isContinuousSpellCheckingEnabled = true
    smartInsertDeleteEnabled = false
    isVerticallyResizable = false
    isHorizontallyResizable = false
    textContainerInset = NSSize(width: NoteFormat.gutter, height: 0)
    insertionPointColor = Theme.accent
    linkTextAttributes = [
      .foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
      .underlineColor: Theme.linkUnderline, .cursor: NSCursor.pointingHand,
    ]
    typingAttributes = NoteFormat.attributes(ListStyle())
  }

  // MARK: Content

  var markdown: String {
    NoteFormat.markdown(textStorage ?? NSTextStorage(), trailingStyle: trailingStyle)
  }

  func load(_ content: String, replacing: Bool = false) {
    guard let storage = textStorage else { return }
    let rendered = NoteFormat.render(content, store: owner?.store)
    storage.setAttributedString(rendered.text)
    trailingStyle = rendered.trailingStyle
    normalize()
    if replacing { undoManager?.removeAllActions() }
    updateTypingAttributes()
  }

  var caretPosition: (paragraph: Int, offset: Int)? {
    let location = selectedRange().location
    guard let index = paragraphIndex(at: location) else { return nil }
    return (index, location - paragraphs[index].range.location)
  }

  func restoreCaret(_ caret: (paragraph: Int, offset: Int)) {
    guard !paragraphs.isEmpty else { return }
    let paragraph = paragraphs[min(caret.paragraph, paragraphs.count - 1)]
    setSelectedRange(NSRange(location: paragraph.range.location + min(caret.offset, paragraph.range.length), length: 0))
  }

  func normalize() {
    guard let storage = textStorage else { return }
    let ranges = NoteFormat.paragraphRanges(storage.string)
    var result: [Paragraph] = []
    var starts: [Int: Int] = [:]
    var previousDepth = -1
    var next: [Int?] = []
    storage.beginEditing()
    for (index, range) in ranges.enumerated() {
      let last = index == ranges.count - 1
      var style: ListStyle
      if range.length > 0 || !last {
        style = NoteFormat.listStyle(storage.attributes(at: range.location, effectiveRange: nil))
      } else {
        style =
          trailingStyle
          ?? (storage.length > 0
            ? NoteFormat.listStyle(storage.attributes(at: storage.length - 1, effectiveRange: nil)) : ListStyle())
      }
      style.depth = max(0, min(style.depth, previousDepth + 1))
      previousDepth = style.depth
      if next.count > style.depth + 1 { next.removeLast(next.count - style.depth - 1) }
      while next.count < style.depth + 1 { next.append(nil) }
      var number = 0
      if style.ordered {
        number = next[style.depth] ?? style.start
        next[style.depth] = number + 1
      } else {
        next[style.depth] = nil
      }
      let full = NSRange(location: range.location, length: range.length + (last ? 0 : 1))
      if full.length > 0 { apply(style, to: full, in: storage) }
      if last { trailingStyle = range.length > 0 ? nil : style }
      let attachment =
        range.length == 1 ? storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NoteAttachment : nil
      starts[range.location] = result.count
      result.append(Paragraph(range: range, style: style, number: number, attachment: attachment))
    }
    storage.endEditing()
    paragraphs = result
    paragraphStarts = starts
    if let hoveredMarker, !paragraphs.indices.contains(hoveredMarker) { self.hoveredMarker = nil }
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  private func apply(_ style: ListStyle, to range: NSRange, in storage: NSTextStorage) {
    var effective = NSRange()
    let current = storage.attributes(at: range.location, longestEffectiveRange: &effective, in: range)
    if NSEqualRanges(effective, range), NoteFormat.listStyle(current) == style,
      (current[.paragraphStyle] as? NSParagraphStyle) === NoteFormat.paragraphStyle(style.depth)
    {
      return
    }
    storage.addAttributes(NoteFormat.listAttributes(style), range: range)
  }

  func paragraphIndex(at location: Int) -> Int? {
    guard !paragraphs.isEmpty else { return nil }
    var low = 0
    var high = paragraphs.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if paragraphs[middle].range.location <= location { low = middle } else { high = middle - 1 }
    }
    return low
  }

  var currentIndex: Int? { paragraphIndex(at: selectedRange().location) }

  private func subtreeEnd(_ index: Int) -> Int {
    var end = index + 1
    while end < paragraphs.count && paragraphs[end].style.depth > paragraphs[index].style.depth { end += 1 }
    return end
  }

  private func updateTypingAttributes() {
    guard let index = currentIndex else { return }
    typingAttributes = NoteFormat.attributes(paragraphs[index].style)
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let layoutManager, let textContainer, let storage = textStorage else { return }
    let origin = textContainerOrigin
    let selection = selectedRange()
    let drawMarker = { (index: Int, paragraph: Paragraph, line: NSRect) in
      let selected = paragraph.attachment is ImageAttachment && selection.length > 0
        && NSLocationInRange(paragraph.range.location, selection)
      let showStar = paragraph.style.starred || self.hoveredMarker == index
      let marker = showStar ? "★ " : self.markerLabel(paragraph)
      let color: NSColor =
        paragraph.style.starred ? Theme.accent : (showStar ? Theme.muted : (selected ? Theme.accent : Theme.faint))
      let text = NSAttributedString(string: marker, attributes: [.font: NoteFormat.font, .foregroundColor: color])
      let right = origin.x + NoteFormat.indent * CGFloat(paragraph.style.depth) + NoteFormat.listPadding
      let y = origin.y + line.minY + (NoteFormat.lineHeight - NoteFormat.textHeight) / 2
      text.draw(at: NSPoint(x: right - text.size().width, y: y))
    }

    let visible = NSRect(
      x: 0, y: dirtyRect.minY - origin.y - 40, width: textContainer.size.width, height: dirtyRect.height + 80)
    let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
    if glyphs.length > 0 {
      layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
        let character = layoutManager.characterIndexForGlyph(at: range.location)
        if let index = self.paragraphStarts[character], index < self.paragraphs.count {
          drawMarker(index, self.paragraphs[index], rect)
        }
      }
    }
    if layoutManager.extraLineFragmentTextContainer === textContainer,
      let index = paragraphStarts[storage.length], index < paragraphs.count, paragraphs[index].range.length == 0
    {
      drawMarker(index, paragraphs[index], layoutManager.extraLineFragmentRect)
    }
  }

  private func markerLabel(_ paragraph: Paragraph) -> String {
    if paragraph.style.ordered { return "\(paragraph.number). " }
    return ["• ", "◦ ", "▪ "][min(paragraph.style.depth, 2)]
  }

  private func markerRect(_ paragraph: Paragraph, line: NSRect, origin: NSPoint) -> NSRect {
    let width = (markerLabel(paragraph) as NSString).size(withAttributes: [.font: NoteFormat.font]).width
    let right = origin.x + NoteFormat.indent * CGFloat(paragraph.style.depth) + NoteFormat.listPadding
    return NSRect(x: right - width - 6, y: origin.y + line.minY, width: width + 6, height: line.height)
  }

  private func markerIndex(at point: NSPoint) -> Int? {
    guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    let origin = textContainerOrigin
    var found: Int?
    let glyphs = layoutManager.glyphRange(for: textContainer)
    if glyphs.length > 0 {
      layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
        let character = layoutManager.characterIndexForGlyph(at: range.location)
        guard let index = self.paragraphStarts[character], index < self.paragraphs.count else { return }
        if self.markerRect(self.paragraphs[index], line: rect, origin: origin).contains(point) { found = index }
      }
    }
    if found == nil, layoutManager.extraLineFragmentTextContainer === textContainer,
      let index = paragraphStarts[storage.length], index < paragraphs.count, paragraphs[index].range.length == 0,
      markerRect(paragraphs[index], line: layoutManager.extraLineFragmentRect, origin: origin).contains(point)
    {
      found = index
    }
    return found
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let markerTracking { removeTrackingArea(markerTracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
    markerTracking = area
    addTrackingArea(area)
  }

  override func mouseMoved(with event: NSEvent) {
    let index = markerIndex(at: convert(event.locationInWindow, from: nil))
    if index != hoveredMarker {
      hoveredMarker = index
      needsDisplay = true
    }
    super.mouseMoved(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    if hoveredMarker != nil {
      hoveredMarker = nil
      needsDisplay = true
    }
    super.mouseExited(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    if let index = markerIndex(at: convert(event.locationInWindow, from: nil)) {
      toggleStar(at: index)
      return
    }
    super.mouseDown(with: event)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard let layoutManager, let textContainer, let storage = textStorage else { return }
    layoutManager.ensureLayout(for: textContainer)
    let origin = textContainerOrigin
    let glyphs = layoutManager.glyphRange(for: textContainer)
    if glyphs.length > 0 {
      layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, _ in
        let character = layoutManager.characterIndexForGlyph(at: range.location)
        guard let index = self.paragraphStarts[character], index < self.paragraphs.count else { return }
        self.addCursorRect(self.markerRect(self.paragraphs[index], line: rect, origin: origin), cursor: .pointingHand)
      }
    }
    if layoutManager.extraLineFragmentTextContainer === textContainer,
      let index = paragraphStarts[storage.length], index < paragraphs.count, paragraphs[index].range.length == 0
    {
      addCursorRect(
        markerRect(paragraphs[index], line: layoutManager.extraLineFragmentRect, origin: origin), cursor: .pointingHand)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    relayoutAttachments()
  }

  func relayoutAttachments() {
    guard let storage = textStorage, let layoutManager else { return }
    layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
    needsDisplay = true
    owner?.textLayoutChanged()
  }

  var contentHeight: CGFloat {
    guard let layoutManager, let textContainer else { return NoteFormat.lineHeight }
    layoutManager.ensureLayout(for: textContainer)
    return max(NoteFormat.lineHeight, layoutManager.usedRect(for: textContainer).height.rounded(.up))
  }

  // MARK: Editing

  override func didChangeText() {
    super.didChangeText()
    normalize()
    updateTypingAttributes()
    owner?.textChanged()
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    updateTypingAttributes()
    needsDisplay = true
  }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { owner?.textFocused() }
    return accepted
  }

  func textDidEndEditing(_ notification: Notification) {
    owner?.textEndedEditing()
  }

  func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
    let value = (link as? String) ?? (link as? URL)?.absoluteString ?? ""
    if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
    }
    return true
  }

  private func replace(_ range: NSRange, with text: NSAttributedString, caret: Int? = nil) {
    breakUndoCoalescing()
    guard let storage = textStorage, shouldChangeText(in: range, replacementString: text.string) else { return }
    storage.replaceCharacters(in: range, with: text)
    didChangeText()
    breakUndoCoalescing()
    setSelectedRange(NSRange(location: caret ?? range.location + text.length, length: 0))
  }

  private func restyle(_ changes: [(index: Int, style: ListStyle)]) {
    guard let storage = textStorage, !changes.isEmpty else { return }
    let ranges = changes.map { change -> NSRange in
      let range = paragraphs[change.index].range
      return NSRange(location: range.location, length: range.length + (change.index < paragraphs.count - 1 ? 1 : 0))
    }
    let union = ranges.dropFirst().reduce(ranges[0]) { NSUnionRange($0, $1) }
    breakUndoCoalescing()
    if union.length > 0 {
      guard shouldChangeText(in: union, replacementString: nil) else { return }
      storage.beginEditing()
      for (range, change) in zip(ranges, changes) where range.length > 0 {
        storage.addAttributes(NoteFormat.listAttributes(change.style), range: range)
      }
      storage.endEditing()
    }
    if let last = changes.last(where: { $0.index == paragraphs.count - 1 }), paragraphs[last.index].range.length == 0 {
      trailingStyle = last.style
    }
    didChangeText()
  }

  func toggleStar(at index: Int) {
    guard paragraphs.indices.contains(index) else { return }
    setStyle(index) { $0.starred.toggle() }
  }

  private func setStyle(_ index: Int, _ change: (inout ListStyle) -> Void) {
    var style = paragraphs[index].style
    change(&style)
    restyle([(index, style)])
  }

  func indent(by delta: Int) {
    guard let index = currentIndex else { return }
    let paragraph = paragraphs[index]
    var root = paragraph.style
    if delta > 0 {
      guard let previous = paragraphs[..<index].last(where: { $0.style.depth <= paragraph.style.depth }),
        previous.style.depth == paragraph.style.depth
      else { return }
      root.start = 1
    } else {
      guard paragraph.style.depth > 0 else { return }
      if let parent = paragraphs[..<index].last(where: { $0.style.depth < paragraph.style.depth }) {
        root.ordered = parent.style.ordered
        root.start = parent.style.start
      }
    }
    root.depth += delta
    var changes = [(index: index, style: root)]
    for child in (index + 1)..<subtreeEnd(index) {
      var style = paragraphs[child].style
      style.depth += delta
      changes.append((child, style))
    }
    let selection = selectedRange()
    restyle(changes)
    setSelectedRange(selection)
  }

  override func insertTab(_ sender: Any?) { indent(by: 1) }
  override func insertBacktab(_ sender: Any?) { indent(by: -1) }
  override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertLineBreak(sender) }

  override func insertNewline(_ sender: Any?) {
    guard let index = currentIndex else { return super.insertNewline(sender) }
    let paragraph = paragraphs[index]
    let selection = selectedRange()
    if selection.length == 0 && paragraph.range.length == 0 {
      if paragraph.style.depth > 0 { return indent(by: -1) }
      if paragraph.style.ordered { return setStyle(index) { $0.ordered = false } }
    }
    var next = paragraph.style
    next.starred = false
    if index == paragraphs.count - 1 && NSMaxRange(selection) >= NSMaxRange(paragraph.range) {
      trailingStyle = next
    }
    replace(selection, with: NSAttributedString(string: "\n", attributes: NoteFormat.attributes(next)))
  }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    let selection = selectedRange()
    if (string as? String) == " ", replacementRange.location == NSNotFound, selection.length == 0,
      let index = currentIndex, let storage = textStorage
    {
      let paragraph = paragraphs[index]
      let prefixRange = NSRange(location: paragraph.range.location, length: selection.location - paragraph.range.location)
      let prefix = (storage.string as NSString).substring(with: prefixRange)
      var style = paragraph.style
      if prefix == "-" && style.ordered {
        style.ordered = false
      } else if prefix.count > 1, prefix.hasSuffix("."), !style.ordered,
        let number = Int(prefix.dropLast()), prefix.dropLast().allSatisfy({ ("0"..."9").contains($0) })
      {
        style.ordered = true
        style.start = number
      }
      if style != paragraph.style {
        convert(index, removing: prefixRange, to: style)
        return
      }
    }
    super.insertText(string, replacementRange: replacementRange)
  }

  private func convert(_ index: Int, removing prefix: NSRange, to style: ListStyle) {
    breakUndoCoalescing()
    guard let storage = textStorage, shouldChangeText(in: prefix, replacementString: "") else { return }
    let last = index == paragraphs.count - 1
    storage.replaceCharacters(in: prefix, with: "")
    let remaining = NSRange(
      location: prefix.location, length: paragraphs[index].range.length - prefix.length + (last ? 0 : 1))
    if remaining.length > 0 {
      storage.addAttributes(NoteFormat.listAttributes(style), range: remaining)
    }
    if last { trailingStyle = style }
    didChangeText()
    setSelectedRange(NSRange(location: prefix.location, length: 0))
  }

  private func wholeAttachmentParagraph(_ selection: NSRange) -> Int? {
    guard let index = paragraphIndex(at: selection.location) else { return nil }
    let paragraph = paragraphs[index]
    return paragraph.attachment != nil && NSEqualRanges(paragraph.range, selection) ? index : nil
  }

  private func removeParagraph(_ index: Int) {
    let paragraph = paragraphs[index]
    var range = paragraph.range
    if index < paragraphs.count - 1 {
      range.length += 1
    } else if index > 0 {
      range = NSRange(location: range.location - 1, length: range.length + 1)
    }
    replace(range, with: NSAttributedString(string: ""))
    let caret = min(range.location, textStorage?.length ?? 0)
    setSelectedRange(NSRange(location: caret, length: 0))
  }

  override func deleteBackward(_ sender: Any?) {
    let selection = selectedRange()
    if let index = wholeAttachmentParagraph(selection) { return removeParagraph(index) }
    if selection.length == 0, let index = currentIndex {
      let paragraph = paragraphs[index]
      if selection.location == paragraph.range.location && index > 0 {
        let previous = paragraphs[index - 1]
        if paragraph.style.depth > previous.style.depth { return indent(by: -1) }
        let sibling = paragraphs[..<index].last { $0.style.depth <= paragraph.style.depth }
        let continuesList = sibling?.style.depth == paragraph.style.depth && sibling?.style.ordered == true
        if paragraph.style.ordered && !continuesList {
          return setStyle(index) { $0.ordered = false }
        }
        if previous.attachment != nil && paragraph.range.length > 0 {
          return setSelectedRange(previous.range)
        }
      } else if selection.location == 0 && paragraph.style.ordered {
        return setStyle(index) { $0.ordered = false }
      }
    }
    super.deleteBackward(sender)
  }

  override func deleteForward(_ sender: Any?) {
    if let index = wholeAttachmentParagraph(selectedRange()) { return removeParagraph(index) }
    super.deleteForward(sender)
  }

  // MARK: Pasteboard

  private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]

  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
    [.noteMarkdown, .fileURL] + NoteTextView.imageTypes + [.string]
  }

  override var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }
  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.noteMarkdown, .string] }

  func selectionMarkdown() -> String {
    guard let storage = textStorage else { return "" }
    let selection = selectedRange()
    guard let first = paragraphIndex(at: selection.location), let last = paragraphIndex(at: NSMaxRange(selection))
    else { return "" }
    if first == last { return NoteFormat.inlineMarkdown(storage, selection) }
    var entries = NoteFormat.entries(storage, range: selection, trailingStyle: trailingStyle)
    let minimum = entries.map(\.depth).min() ?? 0
    for index in entries.indices { entries[index].depth -= minimum }
    return Outline.normalized(entries)
  }

  override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard type == .noteMarkdown || type == .string else { return super.writeSelection(to: pboard, type: type) }
    return pboard.setString(selectionMarkdown(), forType: type)
  }

  override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
    pboard.declareTypes(types, owner: nil)
    return types.map { writeSelection(to: pboard, type: $0) }.contains(true)
  }

  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    let images = imageFiles(pboard)
    if !images.isEmpty {
      insertImages(images)
      return true
    }
    if let markdown = pboard.string(forType: .noteMarkdown) {
      insertMarkdown(markdown)
      return true
    }
    if let text = pboard.string(forType: .string) {
      insertPlain(text)
      return true
    }
    return false
  }

  struct ImageFile {
    var data: Data
    var mimeType: String
    var name: String
  }

  private func imageFiles(_ pboard: NSPasteboard) -> [ImageFile] {
    let urls =
      pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    var files: [ImageFile] = urls.compactMap { url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
      guard size <= NoteStore.maxImageBytes, let data = try? Data(contentsOf: url),
        let mime = ImageData.mimeType(data)
      else { return nil }
      return ImageFile(data: data, mimeType: mime, name: url.lastPathComponent)
    }
    if files.isEmpty && !urls.isEmpty { return [] }
    if files.isEmpty {
      if let png = pboard.data(forType: .png) {
        files.append(ImageFile(data: png, mimeType: "image/png", name: "Pasted image"))
      } else if let jpeg = pboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
        files.append(ImageFile(data: jpeg, mimeType: "image/jpeg", name: "Pasted image"))
      } else if let tiff = pboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
      {
        files.append(ImageFile(data: png, mimeType: "image/png", name: "Pasted image"))
      }
    }
    return files.filter { $0.data.count <= NoteStore.maxImageBytes && ImageData.hasSignature($0.data, $0.mimeType) }
  }

  func insertImages(_ files: [ImageFile]) {
    guard let owner, let index = currentIndex else { return }
    var ids: [(String, String)] = []
    for file in files {
      let rep = NSBitmapImageRep(data: file.data)
      do {
        let id = try owner.store.saveImage(
          data: file.data, mimeType: file.mimeType, fileName: ImageAttachment.cleanAlt(file.name),
          width: rep?.pixelsWide, height: rep?.pixelsHigh)
        ids.append((id, ImageAttachment.cleanAlt(file.name)))
      } catch {
        NSSound.beep()
      }
    }
    guard !ids.isEmpty else { return }
    let current = paragraphs[index]
    let style = ListStyle(depth: current.style.depth, ordered: false, start: 1)
    let items = NSMutableAttributedString()
    for (offset, (id, alt)) in ids.enumerated() {
      if offset > 0 { items.append(NSAttributedString(string: "\n", attributes: NoteFormat.attributes(style))) }
      items.append(
        NoteFormat.body("![\(alt)](noterepo:image:\(id))", attributes: NoteFormat.attributes(style), store: owner.store))
    }
    insertItems(items, style: style, after: index)
  }

  private func insertItems(_ items: NSAttributedString, style: ListStyle, after index: Int) {
    let current = paragraphs[index]
    if current.range.length == 0 {
      if index == paragraphs.count - 1 { trailingStyle = nil }
      replace(current.range, with: items)
      return
    }
    let end = subtreeEnd(index)
    if end < paragraphs.count {
      let text = NSMutableAttributedString(attributedString: items)
      text.append(NSAttributedString(string: "\n", attributes: NoteFormat.attributes(style)))
      replace(NSRange(location: paragraphs[end].range.location, length: 0), with: text,
        caret: paragraphs[end].range.location + items.length)
    } else {
      let last = paragraphs[paragraphs.count - 1]
      let text = NSMutableAttributedString(string: "\n", attributes: NoteFormat.attributes(last.style))
      text.append(items)
      replace(NSRange(location: NSMaxRange(last.range), length: 0), with: text)
    }
  }

  private func openItemAfter(_ index: Int) {
    guard index < paragraphs.count else { return }
    let paragraph = paragraphs[index]
    if index + 1 < paragraphs.count, paragraphs[index + 1].range.length == 0,
      paragraphs[index + 1].style.depth == paragraph.style.depth
    {
      return setSelectedRange(NSRange(location: paragraphs[index + 1].range.location, length: 0))
    }
    setSelectedRange(NSRange(location: NSMaxRange(paragraph.range), length: 0))
    insertNewline(nil)
  }

  func insertPlain(_ raw: String) {
    let text = NoteFormat.cleanPasted(raw)
    guard !text.isEmpty else { return }
    if text.contains("\n") { return insertLines(text.components(separatedBy: "\n")) }
    insertLine(text)
  }

  private func insertLine(_ text: String) {
    guard let index = currentIndex, let owner else { return }
    let paragraph = paragraphs[index]
    let attributes = NoteFormat.attributes(paragraph.style)
    let selection = selectedRange()
    let emptyParagraph = paragraph.range.length == 0 || NSEqualRanges(selection, paragraph.range)

    if Links.imageItem(text) != nil {
      return insertItems(NoteFormat.body(text, attributes: NoteFormat.attributes(ListStyle(depth: paragraph.style.depth)), store: owner.store),
        style: ListStyle(depth: paragraph.style.depth), after: index)
    }
    if text.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
      return insertLink(text, attributes: attributes, soleItem: emptyParagraph)
    }
    replace(selection, with: NoteFormat.body(text, attributes: attributes, store: owner.store))
  }

  private func insertLink(_ url: String, attributes: [NSAttributedString.Key: Any], soleItem: Bool) {
    let escaped = Links.escapeURL(url)
    let token = UUID().uuidString
    var linkAttributes = attributes
    linkAttributes[.link] = escaped
    linkAttributes[.noteLinkToken] = token
    replace(selectedRange(), with: NSAttributedString(string: escaped, attributes: linkAttributes))
    if soleItem, let index = currentIndex { openItemAfter(index) }
    Task { @MainActor [weak self] in
      let title = await LinkTitles.fetch(escaped)
      self?.applyTitle(title, token: token, url: escaped)
    }
  }

  private func applyTitle(_ title: String?, token: String, url: String) {
    guard let storage = textStorage else { return }
    var found: NSRange?
    storage.enumerateAttribute(.noteLinkToken, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
      if value as? String == token {
        found = range
        stop.pointee = true
      }
    }
    guard let range = found else { return }
    guard let title, (storage.string as NSString).substring(with: range) == url else {
      storage.removeAttribute(.noteLinkToken, range: range)
      return
    }
    var attributes = storage.attributes(at: range.location, effectiveRange: nil)
    attributes[.noteLinkToken] = nil
    var plain = attributes
    plain[.link] = nil
    let text = NSMutableAttributedString(string: Links.cleanTitle(title), attributes: attributes)
    text.append(NSAttributedString(string: " (\(Links.domain(url)))", attributes: plain))
    let selection = selectedRange()
    let caretAtLink = selection.length == 0 && selection.location > range.location && selection.location <= NSMaxRange(range)
    let shift = text.length - range.length
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: text.string) else { return }
    storage.replaceCharacters(in: range, with: text)
    didChangeText()
    breakUndoCoalescing()
    if caretAtLink {
      setSelectedRange(NSRange(location: range.location + text.length, length: 0))
    } else if selection.location > range.location {
      setSelectedRange(NSRange(location: selection.location + shift, length: selection.length))
    } else {
      setSelectedRange(selection)
    }
  }

  private func insertLines(_ lines: [String]) {
    guard let index = currentIndex, let owner else { return }
    let base = paragraphs[index].style
    var entries: [OutlineEntry] = []
    for line in lines {
      let entry = Outline.parseLine(line, previousDepth: entries.last?.depth ?? -1)
      entry.body = entry.body.trimmingCharacters(in: .whitespaces)
      entries.append(entry)
    }
    let minimum = entries.map(\.depth).min() ?? 0
    let text = NSMutableAttributedString()
    var previous = base
    for (offset, entry) in entries.enumerated() {
      let split = Outline.splitStar(entry.body)
      var style =
        offset == 0
        ? base : ListStyle(depth: base.depth + entry.depth - minimum, ordered: entry.ordered, start: entry.start)
      style.starred = split.starred || (offset == 0 && base.starred)
      if offset > 0 { text.append(NSAttributedString(string: "\n", attributes: NoteFormat.attributes(previous))) }
      text.append(NoteFormat.body(split.text, attributes: NoteFormat.attributes(style), store: owner.store))
      previous = style
    }
    replace(selectedRange(), with: text)
  }

  func insertMarkdown(_ markdown: String) {
    if markdown.contains("\n") { return insertLines(markdown.components(separatedBy: "\n")) }
    insertLine(markdown)
  }
}
