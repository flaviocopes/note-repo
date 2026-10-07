import AppKit
import NoteRepoCore

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

final class DayView: NSView, NoteTextViewOwner {
  static let padding = NSEdgeInsets(top: 32, left: 40, bottom: 32, right: 40)
  static let headerGap: CGFloat = 14

  let date: String
  let header: NSTextField
  let textView = NoteTextView.make()
  unowned let feed: FeedController
  var base: String
  let starredOnly: Bool
  var lastSaved = ""
  var content = ""
  private var saveTimer: Timer?

  var store: NoteStore { feed.store }
  var isToday: Bool { date == Day.today }

  init(note: Note, feed: FeedController) {
    starredOnly = feed.model?.showsStarred == true
    date = note.date
    base = note.content
    self.feed = feed
    header = NSTextField(labelWithString: Day.title(note.date))
    super.init(frame: .zero)
    header.font = Theme.mono(12, .medium)
    header.textColor = Theme.muted
    addSubview(header)
    textView.owner = self
    addSubview(textView)
    let shown = starredOnly ? Self.starredContent(note.content) : note.content
    textView.load(shown)
    textView.isEditable = !starredOnly
    content = starredOnly ? note.content : textView.markdown
    lastSaved = content
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  private var contentWidth: CGFloat {
    max(120, min(bounds.width - DayView.padding.left - DayView.padding.right, 720))
  }

  private var headerHeight: CGFloat { ceil(header.intrinsicContentSize.height) }

  private func textWidth(for width: CGFloat) -> CGFloat {
    max(120, min(width - DayView.padding.left - DayView.padding.right, 720))
  }

  func height(width: CGFloat, viewport: CGFloat) -> CGFloat {
    let textFrameWidth = textWidth(for: width) + NoteFormat.gutter * 2
    if abs(textView.frame.width - textFrameWidth) > 0.5 {
      textView.setFrameSize(NSSize(width: textFrameWidth, height: textView.frame.height))
    }
    let chrome = DayView.padding.top + headerHeight + DayView.headerGap + DayView.padding.bottom
    let natural = chrome + textView.contentHeight
    return isToday && !starredOnly ? max(natural, viewport) : natural
  }

  override func layout() {
    super.layout()
    let left = DayView.padding.left
    header.frame = NSRect(x: left, y: DayView.padding.top, width: contentWidth, height: headerHeight)
    let top = header.frame.maxY + DayView.headerGap
    let textHeight = max(textView.contentHeight, bounds.height - top - DayView.padding.bottom)
    textView.frame = NSRect(
      x: left - NoteFormat.gutter, y: top, width: contentWidth + NoteFormat.gutter * 2, height: textHeight)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !isToday else { return }
    Theme.divider.setFill()
    NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
  }

  func focusEnd() {
    window?.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
  }

  static func starredContent(_ content: String) -> String {
    let entries = Outline.parse(content).filter { Outline.splitStar($0.body).starred }
    for entry in entries { entry.depth = 0; entry.dirty = true }
    return Outline.normalized(entries)
  }

  func toggleStar(at index: Int) -> Bool {
    guard starredOnly else { return false }
    let entries = Outline.parse(base)
    let stars = entries.filter { Outline.splitStar($0.body).starred }
    guard stars.indices.contains(index) else { return true }
    stars[index].body = Outline.splitStar(stars[index].body).text
    stars[index].dirty = true
    feed.saveStarChange(date: date, content: Outline.serialize(entries), base: base)
    return true
  }

  // MARK: Saving

  func textChanged() {
    guard !starredOnly else { return }
    content = textView.markdown
    feed.saveStateChanged(date: date, error: nil)
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.save() }
    }
    feed.dayResized(self)
  }

  func textFocused() { feed.dayFocused(self) }
  func textLayoutChanged() { feed.dayResized(self) }
  func textEndedEditing() { save() }

  func save() {
    guard !starredOnly else { return }
    saveTimer?.invalidate()
    saveTimer = nil
    guard content != lastSaved else { return }
    let text = content
    do {
      let saved = try store.save(date, text, base: base)
      lastSaved = text
      if saved.content == text {
        base = saved.content
      } else if content == text {
        apply(saved.content)
      } else {
        base = text
      }
      feed.saveStateChanged(date: date, error: nil)
    } catch {
      feed.saveStateChanged(date: date, error: "Could not save")
    }
  }

  func apply(_ newContent: String) {
    let focused = window?.firstResponder === textView
    let caret = focused ? textView.caretPosition : nil
    textView.load(newContent, replacing: true)
    content = textView.markdown
    lastSaved = content
    base = newContent
    if let caret { textView.restoreCaret(caret) }
    feed.dayResized(self)
  }
}

@MainActor
final class FeedController: NSObject {
  let store: NoteStore
  weak var model: AppModel?
  let scrollView = NSScrollView()
  let document = FlippedView()
  private(set) var days: [DayView] = []
  private var hasMoreBefore = false
  private var hasMoreAfter = false
  private var adjusting = false
  private var watcher: Timer?
  private var dataVersion = 0
  private var versions: [String: String] = [:]
  private var lastSize = NSSize.zero
  private let emptyLabel = NSTextField(labelWithString: "No starred items")

  init(store: NoteStore) {
    self.store = store
    super.init()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets()
    scrollView.documentView = document
    emptyLabel.font = Theme.mono(12)
    emptyLabel.textColor = Theme.muted
    emptyLabel.isHidden = true
    document.addSubview(emptyLabel)
    scrollView.contentView.postsBoundsChangedNotifications = true
    scrollView.contentView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    NotificationCenter.default.addObserver(
      self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
    dataVersion = (try? store.dataVersion()) ?? 0
    versions = (try? store.versions()) ?? [:]
    watcher = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkOutsideChanges() }
    }
  }

  private var viewport: NSRect { scrollView.contentView.bounds }

  private func makeDay(_ note: Note) -> DayView { DayView(note: note, feed: self) }

  private func todayNote() -> Note { (try? store.get(Day.today)) ?? Note(date: Day.today, content: "", updatedAt: nil) }

  // MARK: Loading

  private var pendingAnchor: String?
  private var scrollTarget: DayView?

  func load(anchor requested: String) {
    let today = Day.today
    let date = requested < today ? requested : today
    guard viewport.height > 0 else {
      pendingAnchor = date
      return
    }
    pendingAnchor = nil
    flushSaves()
    days.forEach { $0.removeFromSuperview() }
    if model?.showsStarred == true {
      hasMoreBefore = false
      hasMoreAfter = false
      let notes = ((try? store.notesContainingStar()) ?? []).reversed().filter {
        $0.date <= today && Outline.describe(Outline.parse($0.content)).contains(where: \.starred)
      }
      days = notes.map(makeDay)
      days.forEach(document.addSubview)
      scrollTarget = nil
      relayout(keepAnchor: false)
      setTop(0)
      updateActive()
      return
    }
    let earlier = (try? store.notesBefore(date, limit: 7)) ?? []
    hasMoreBefore = earlier.count == 7
    var notes = earlier
    hasMoreAfter = false
    if date == today {
      notes.append(todayNote())
    } else {
      if (try? store.has(date)) == true, let note = try? store.get(date) { notes.append(note) }
      let later = ((try? store.notesAfter(date, limit: 7)) ?? []).filter { $0.date < today }
      notes += later
      if later.count < 7 { notes.append(todayNote()) } else { hasMoreAfter = true }
    }
    days = notes.map(makeDay)
    days.forEach(document.addSubview)
    relayout(keepAnchor: false)
    scroll(toClosest: date, animated: false)
  }

  private func loadBefore() {
    guard hasMoreBefore, let first = days.first else { return }
    let notes = (try? store.notesBefore(first.date, limit: 14)) ?? []
    hasMoreBefore = notes.count == 14
    guard !notes.isEmpty else { return }
    let added = notes.map(makeDay)
    added.forEach(document.addSubview)
    days.insert(contentsOf: added, at: 0)
    relayout()
  }

  private func loadAfter() {
    guard hasMoreAfter, let last = days.last else { return }
    let today = Day.today
    let notes = ((try? store.notesAfter(last.date, limit: 14)) ?? []).filter { $0.date < today }
    var added = notes.map(makeDay)
    hasMoreAfter = notes.count == 14
    if !hasMoreAfter { added.append(makeDay(todayNote())) }
    added.forEach(document.addSubview)
    days += added
    relayout()
  }

  // MARK: Layout

  private func visibleAnchor() -> (day: DayView, offset: CGFloat)? {
    let top = viewport.minY
    guard let day = days.first(where: { $0.frame.maxY > top }) else { return nil }
    return (day, day.frame.minY - top)
  }

  func relayout(keepAnchor: Bool = true) {
    let anchor = keepAnchor ? visibleAnchor() : nil
    let width = viewport.width
    let height = viewport.height
    var y: CGFloat = 0
    for day in days {
      let dayHeight = day.height(width: width, viewport: height)
      day.frame = NSRect(x: 0, y: y, width: width, height: dayHeight)
      day.needsLayout = true
      day.needsDisplay = true
      y += dayHeight
    }
    emptyLabel.isHidden = model?.showsStarred != true || !days.isEmpty
    emptyLabel.frame = NSRect(x: 40, y: 52, width: max(0, width - 80), height: 24)
    adjusting = true
    document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, height))
    if let target = scrollTarget, days.contains(where: { $0 === target }) {
      scrollTarget = nil
      setTop(target.frame.minY)
    } else if let anchor, days.contains(where: { $0 === anchor.day }) {
      setTop(anchor.day.frame.minY - anchor.offset)
    }
    adjusting = false
    lastSize = viewport.size
  }

  private func setTop(_ value: CGFloat, animated: Bool = false) {
    let top = max(0, min(value, document.frame.height - viewport.height))
    let point = NSPoint(x: 0, y: top)
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.28
        scrollView.contentView.animator().setBoundsOrigin(point)
      } completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          self?.scrollTarget = nil
          self?.updateActive()
        }
      }
    } else {
      scrollView.contentView.scroll(to: point)
    }
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  @objc private func resized() {
    guard viewport.size != lastSize, !adjusting, viewport.height > 0 else { return }
    if let anchor = pendingAnchor { return load(anchor: anchor) }
    relayout()
  }

  @objc private func scrolled() {
    guard !adjusting else { return }
    updateActive()
    if viewport.minY < 600 && hasMoreBefore { loadBefore() }
    if viewport.maxY > document.frame.height - 600 && hasMoreAfter { loadAfter() }
  }

  func dayResized(_ day: DayView) {
    relayout()
  }

  func updateActive() {
    let marker = viewport.minY + 40
    var active = days.first
    for day in days {
      if day.frame.minY <= marker { active = day } else { break }
    }
    if let active, model?.activeDate != active.date { model?.activeDate = active.date }
  }

  // MARK: Navigation

  private func scroll(toClosest date: String, animated: Bool) {
    guard !days.isEmpty else { return }
    let target = Day.date(date)?.timeIntervalSince1970 ?? 0
    let day =
      days.first { $0.date == date }
      ?? days.min {
        abs((Day.date($0.date)?.timeIntervalSince1970 ?? 0) - target)
          < abs((Day.date($1.date)?.timeIntervalSince1970 ?? 0) - target)
      }!
    scrollTarget = animated ? day : nil
    setTop(day.frame.minY, animated: animated)
    if model?.activeDate != day.date { model?.activeDate = day.date }
  }

  func jump(to requested: String, focus: Bool, animated: Bool = true) {
    let date = min(requested, Day.today)
    if let day = days.first(where: { $0.date == date }) {
      scroll(toClosest: date, animated: animated)
      if focus { day.focusEnd() }
      return
    }
    load(anchor: date)
    if focus { days.first(where: { $0.date == date })?.focusEnd() }
  }

  func moveDay(_ direction: Int) {
    guard let index = days.firstIndex(where: { $0.date == model?.activeDate }) else { return }
    let target = index + direction
    guard days.indices.contains(target) else { return }
    scroll(toClosest: days[target].date, animated: true)
  }

  func dayFocused(_ day: DayView) {
    if model?.activeDate != day.date { model?.activeDate = day.date }
  }

  func saveStateChanged(date: String, error: String?) {
    guard date == model?.activeDate || error == nil else { return }
    if model?.saveError != error { model?.saveError = error }
  }

  func flushSaves() {
    days.forEach { $0.save() }
  }

  func saveStarChange(date: String, content: String, base: String) {
    do {
      let saved = try store.save(date, content, base: base)
      scrollView.window?.undoManager?.registerUndo(withTarget: self) { feed in
        feed.saveStarChange(date: date, content: base, base: saved.content)
      }
      scrollView.window?.undoManager?.setActionName("Unstar item")
      saveStateChanged(date: date, error: nil)
      load(anchor: model?.activeDate ?? Day.today)
    } catch {
      saveStateChanged(date: date, error: "Could not save")
    }
  }

  // MARK: Outside changes

  private func checkOutsideChanges() {
    guard let current = try? store.dataVersion(), current != dataVersion else { return }
    dataVersion = current
    let next = (try? store.versions()) ?? [:]
    let dates = Set(versions.keys).union(next.keys).filter { versions[$0] != next[$0] }.sorted()
    versions = next
    let changed = dates.filter { $0 <= Day.today }
    guard !changed.isEmpty else { return }
    if model?.showsStarred == true {
      load(anchor: model?.activeDate ?? Day.today)
      return
    }
    if changed.count > 10 {
      load(anchor: model?.activeDate ?? Day.today)
      return
    }
    changed.forEach(refresh)
    updateActive()
  }

  private func refresh(_ date: String) {
    guard let note = try? store.get(date) else { return }
    if let day = days.first(where: { $0.date == date }) {
      if note.content == day.base { return }
      if day.content != day.lastSaved { return day.save() }
      if !Outline.hasContent(note.content) && date != Day.today {
        day.removeFromSuperview()
        days.removeAll { $0 === day }
        return relayout()
      }
      return day.apply(note.content)
    }
    guard Outline.hasContent(note.content), let index = days.firstIndex(where: { $0.date > date }) else { return }
    if index == 0 && hasMoreBefore { return }
    let day = makeDay(note)
    document.addSubview(day)
    days.insert(day, at: index)
    relayout()
  }
}
