import AppKit
import NoteRepoCore

@MainActor
enum Automation {
  static let snapshot = Notification.Name("com.flaviocopes.noterepo.native.snapshot")
  static let command = Notification.Name("com.flaviocopes.noterepo.native.command")

  static func start(_ model: AppModel) {
    let center = DistributedNotificationCenter.default()
    center.addObserver(forName: snapshot, object: nil, queue: .main) { note in
      guard let path = note.object as? String else { return }
      MainActor.assumeIsolated { save(to: path) }
    }
    center.addObserver(forName: command, object: nil, queue: .main) { note in
      guard let command = note.object as? String else { return }
      MainActor.assumeIsolated { run(command, model) }
    }
  }

  static func run(_ command: String, _ model: AppModel) {
    let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first {
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "jump": model.jump(to: parts.count > 1 ? parts[1] : Day.today)
    case "today": model.focusToday()
    case "search":
      model.focusSearch()
      model.query = parts.count > 1 ? parts[1] : ""
      model.runSearch()
    case "close-search": model.closeSearch()
    case "select-image":
      for day in model.feed.days {
        if let paragraph = day.textView.paragraphs.first(where: { $0.attachment is ImageAttachment }) {
          day.window?.makeFirstResponder(day.textView)
          day.textView.setSelectedRange(paragraph.range)
        }
      }
    default: break
    }
  }

  static func save(to path: String) {
    guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView?.superview,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}
