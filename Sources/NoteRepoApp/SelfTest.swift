import AppKit
import NoteRepoCore
import SwiftUI

@MainActor
enum SelfTest {
  static var failures: [String] = []

  static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    print(condition ? "ok  " : "FAIL", name, condition ? "" : detail())
    if !condition { failures.append(name) }
  }

  static func wait(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
  }

  static func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) async {
    let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let event = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
      else { continue }
      NSApp.postEvent(event, atStart: false)
    }
    await wait(0.15)
  }

  static func undo(_ view: NoteTextView) async {
    if NSApp.keyWindow != nil {
      await press("z", keyCode: 6, modifiers: .command)
    } else {
      view.undoManager?.undo()
    }
  }

  static func type(_ view: NoteTextView, _ text: String) {
    for character in text {
      view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
  }

  static func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }

  static func paste(_ view: NoteTextView, _ text: String) {
    let board = NSPasteboard(name: NSPasteboard.Name("NoteRepoSelfTest"))
    board.clearContents()
    board.setString(text, forType: .string)
    _ = view.readSelection(from: board, type: .string)
  }

  static func roundTrip(_ store: NoteStore) -> Never {
    let notes = (try? store.notesAfter("0000-01-01", limit: 100_000)) ?? []
    var mismatches: [String] = []
    var differing = 0
    for note in notes {
      let rendered = NoteFormat.render(note.content, store: store)
      let storage = NSTextStorage(attributedString: rendered.text)
      let view = NoteTextView.make()
      view.textStorage?.setAttributedString(storage)
      view.trailingStyle = rendered.trailingStyle
      view.normalize()
      let expected = Outline.normalized(Outline.parse(note.content)).replacingOccurrences(of: "\u{00a0}", with: " ")
      if !view.markdown.unicodeScalars.elementsEqual(expected.unicodeScalars) {
        let pairs = zip(Outline.lines(view.markdown), Outline.lines(expected)).filter {
          !$0.unicodeScalars.elementsEqual($1.unicodeScalars)
        }
        differing += 1
        mismatches.append("\(note.date): \(pairs.count) of \(Outline.lines(expected).count) lines differ")
        if CommandLine.arguments.contains("--show-lines") {
          for (native, web) in pairs {
            let a = Array(native.unicodeScalars)
            let b = Array(web.unicodeScalars)
            let index = (0..<min(a.count, b.count)).first { a[$0] != b[$0] } ?? min(a.count, b.count)
            let show = { (scalars: [Unicode.Scalar]) in
              scalars[max(0, index - 3)..<min(scalars.count, index + 3)].map { String(format: "U+%04X", $0.value) }
                .joined(separator: " ")
            }
            mismatches.append("    at \(index): native \(show(a)) / web \(show(b)), lengths \(a.count) / \(b.count)")
          }
        }
      }
    }
    print("round trip: \(notes.count) days, \(differing) differ from the web editor's output")
    mismatches.forEach { print("  \($0)") }
    exit(differing == 0 ? 0 : 1)
  }

  static func run(_ model: AppModel) async {
    setvbuf(stdout, nil, _IONBF, 0)
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
    await wait(1)
    guard let today = model.feed.days.last, today.isToday else {
      print("FAIL no today section")
      exit(1)
    }
    let view = today.textView
    today.focusEnd()
    view.selectAll(nil)
    view.deleteBackward(nil)

    type(view, "Buy milk")
    view.insertNewline(nil)
    view.insertTab(nil)
    type(view, "Oat")
    view.insertNewline(nil)
    view.insertBacktab(nil)
    type(view, "Call Anna")
    check("nesting with Tab and Shift-Tab", view.markdown == "- Buy milk\n  - Oat\n- Call Anna", view.markdown)

    view.insertTab(nil)
    check("Tab needs a previous sibling", view.markdown == "- Buy milk\n  - Oat\n  - Call Anna", view.markdown)
    view.insertBacktab(nil)

    view.insertNewline(nil)
    type(view, "1. First")
    view.insertNewline(nil)
    type(view, "Second")
    check("typing 1. starts a numbered list", view.markdown.hasSuffix("- Call Anna\n1. First\n2. Second"), view.markdown)

    view.insertNewline(nil)
    view.insertNewline(nil)
    type(view, "After the list")
    check("Enter on an empty numbered item ends the list", view.markdown.hasSuffix("2. Second\n- After the list"), view.markdown)

    view.insertNewline(nil)
    view.insertTab(nil)
    view.insertNewline(nil)
    check("Enter on an empty nested item outdents it", view.markdown.hasSuffix("- After the list\n"), view.markdown)
    check("the empty item stays at the top level", view.paragraphs.last?.style.depth == 0)
    view.layoutManager!.ensureLayout(for: view.textContainer!)
    let emptyLine = view.layoutManager!.extraLineFragmentRect
    check("the caret on an empty last item is a full line tall", emptyLine.height == NoteFormat.lineHeight, "\(emptyLine)")

    let itemCount = view.paragraphs.count
    type(view, "Groceries")
    await press("\r", keyCode: 36, modifiers: .option)
    type(view, "milk, eggs")
    check(
      "Option-Return breaks the line inside the item",
      view.paragraphs.count == itemCount && view.markdown.hasSuffix("- After the list\n- Groceries<br>milk, eggs"),
      view.markdown)
    let reloaded = NoteTextView.make()
    reloaded.load(view.markdown)
    check(
      "a line break inside an item survives a reload",
      reloaded.markdown == view.markdown && reloaded.textStorage!.string.hasSuffix("Groceries\u{2028}milk, eggs"),
      reloaded.markdown)

    let groceries = view.paragraphs.count - 1
    view.toggleStar(at: groceries)
    check(
      "clicking the bullet stars the item",
      view.paragraphs[groceries].style.starred && view.markdown.hasSuffix("- ★ Groceries<br>milk, eggs"),
      view.markdown)
    check("the star stays in the margin", !view.textStorage!.string.contains("★"))
    let starred = NoteTextView.make()
    starred.load(view.markdown)
    check(
      "a star survives a reload",
      starred.paragraphs[groceries].style.starred && !starred.textStorage!.string.contains("★"),
      starred.markdown)
    today.save()
    check(
      "starred items show in the sidebar",
      model.starred.contains { $0.text.hasPrefix("Groceries") },
      model.starred.map(\.text).joined(separator: ", "))
    await undo(view)
    check("undo removes the star", !view.markdown.contains("★") && view.paragraphs[groceries].style.starred == false, view.markdown)
    view.insertNewline(nil)

    paste(view, "https://flaviocopes.com")
    check("a pasted link becomes its own item", view.markdown.hasSuffix("- https://flaviocopes.com\n"), view.markdown)
    var titled = false
    for _ in 0..<40 where !titled {
      await wait(0.25)
      titled = view.markdown.contains("](https://flaviocopes.com) (flaviocopes.com)")
    }
    check("the link gets its page title", titled, view.markdown)
    check("the caret moved to a new item", view.paragraphs[view.currentIndex ?? 0].range.length == 0)

    paste(view, "https://x.com/jack/status/20")
    var postTitled = false
    for _ in 0..<40 where !postTitled {
      await wait(0.25)
      postTitled = view.markdown.contains("\n- [just setting up my twttr](https://x.com/jack/status/20) (x.com)")
    }
    check("an X post gets the first line of its text", postTitled, view.markdown)

    let board = NSPasteboard(name: NSPasteboard.Name("NoteRepoSelfTestImage"))
    board.clearContents()
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    board.setData(png, forType: .png)
    _ = view.readSelection(from: board, type: .png)
    check("a pasted image becomes an item", view.markdown.contains("- ![Pasted image](noterepo:image:"), view.markdown)
    check("the image is stored", view.paragraphs.contains { ($0.attachment as? ImageAttachment)?.entry.image != nil })

    if let index = view.paragraphs.firstIndex(where: { $0.attachment is ImageAttachment }) {
      await press("\u{f703}", keyCode: 124)
      view.setSelectedRange(view.paragraphs[index].range)
      await press("\u{7f}", keyCode: 51)
      check("Backspace removes a selected image item", !view.markdown.contains("noterepo:image:"), view.markdown)
      await undo(view)
      check("undo brings the image back", view.markdown.contains("noterepo:image:"), view.markdown)
    }

    await wait(0.6)
    today.save()
    let saved = (try? model.store.get(Day.today).content) ?? ""
    check("the day is saved", saved == view.markdown, "saved: \(saved)\nshown: \(view.markdown)")

    let outside = try! NoteStore(url: model.store.url)
    try! outside.save(Day.today, saved + "\n- Added by the CLI")
    await wait(1.2)
    check("outside changes show up", view.markdown.hasSuffix("- Added by the CLI"), view.markdown)

    view.setSelectedRange(NSRange(location: view.textStorage!.length, length: 0))
    for (character, code) in [(" ", UInt16(49)), ("n", 45), ("o", 31), ("w", 13)] {
      await press(character, keyCode: code)
    }
    check("typing through key events", view.markdown.hasSuffix("- Added by the CLI now"), view.markdown)
    await undo(view)
    check("undo removes typing", view.markdown.hasSuffix("- Added by the CLI"), view.markdown)

    view.insertNewline(nil)
    type(view, "Typed while the CLI writes")
    try! outside.save(Day.today, "- From the CLI first\n" + ((try? outside.get(Day.today).content) ?? ""))
    today.save()
    let merged = (try? model.store.get(Day.today).content) ?? ""
    check(
      "edits merge with outside changes",
      merged.hasPrefix("- From the CLI first") && merged.hasSuffix("- Typed while the CLI writes"), merged)
    await wait(0.8)
    check("the merged text is shown", view.markdown == merged, view.markdown)

    let earlier = Day.adding(-3, to: Day.today)
    try! outside.save(earlier, "- Earlier day")
    await wait(1.2)
    let earlierDay = model.feed.days.first { $0.date == earlier }
    check("a day written by the CLI shows up", earlierDay != nil)
    if let earlierDay, let index = view.paragraphs.firstIndex(where: { $0.attachment is ImageAttachment }) {
      let board = NSPasteboard(name: NSPasteboard.Name("NoteRepoSelfTestMove"))
      board.clearContents()
      view.setSelectedRange(view.paragraphs[index].range)
      _ = view.writeSelection(to: board, types: view.writablePasteboardTypes)
      view.deleteBackward(nil)
      earlierDay.focusEnd()
      _ = earlierDay.textView.readSelection(from: board, type: .noteMarkdown)
      check(
        "cut and paste moves an image to another day",
        !view.markdown.contains("noterepo:image:")
          && earlierDay.textView.markdown.hasPrefix("- Earlier day\n- ![Pasted image](noterepo:image:"),
        earlierDay.textView.markdown)
    }

    model.open(URL(string: "noterepo://day/\(earlier)")!)
    await wait(0.4)
    check("a noterepo://day link opens that day", model.activeDate == earlier, model.activeDate)
    model.open(URL(string: "noterepo://today")!)
    await wait(0.4)
    check("a noterepo://today link opens today", model.activeDate == Day.today, model.activeDate)

    view.selectAll(nil)
    check("copy writes Markdown", view.selectionMarkdown() == view.markdown, view.selectionMarkdown())

    let appMenu = NSApp.mainMenu?.items.first?.submenu?.items.map(\.title) ?? []
    check("the app menu has Check for Updates…", appMenu.contains("Check for Updates…"), "\(appMenu)")

    let shownResults = model.results
    model.results = (1...20).map {
      SearchResult(date: Day.adding(-$0, to: Day.today), label: "Day \($0)", excerpt: "- Try the new cli tool")
    }
    let panel = NSHostingView(rootView: SearchResultsView(model: model))
    panel.frame.size = panel.fittingSize
    panel.layoutSubtreeIfNeeded()
    let list = descendants(panel).compactMap { $0 as? NSScrollView }.first
    let listFrame = list.map { $0.convert($0.bounds, to: panel) } ?? .null
    check(
      "many search results scroll inside their panel",
      panel.bounds.height <= 260 && panel.bounds.insetBy(dx: -1, dy: -1).contains(listFrame),
      "panel \(panel.bounds), list \(listFrame)")
    model.results = shownResults

    print(failures.isEmpty ? "self-test passed" : "self-test failed: \(failures.count)")
    exit(failures.isEmpty ? 0 : 1)
  }
}
