import AppKit
import NoteRepoCore
import Observation

struct SearchResult: Identifiable {
  var id: String { date }
  let date: String
  let label: String
  let excerpt: String
}

@MainActor
@Observable
final class AppModel {
  @ObservationIgnored let store: NoteStore
  @ObservationIgnored let feed: FeedController
  var activeDate = Day.today
  var query = ""
  var results: [SearchResult] = []
  var searchOpen = false
  var searchFocusRequest = 0
  var saveError: String?
  @ObservationIgnored private var searchTask: Task<Void, Never>?

  init(store: NoteStore) {
    self.store = store
    feed = FeedController(store: store)
    feed.model = self
  }

  static func dataURL(arguments: [String] = CommandLine.arguments) -> URL {
    for (index, argument) in arguments.enumerated() {
      if argument.hasPrefix("--user-data-dir=") {
        return URL(fileURLWithPath: String(argument.dropFirst("--user-data-dir=".count))).appendingPathComponent(
          "notes.sqlite3")
      }
      if argument == "--user-data-dir", index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("notes.sqlite3")
      }
    }
    return NoteStore.defaultURL
  }

  func queryChanged() {
    searchTask?.cancel()
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(220))
      guard !Task.isCancelled else { return }
      self?.runSearch()
    }
  }

  func runSearch() {
    let notes = (try? store.search(query)) ?? []
    results = notes.map { note in
      let excerpt = note.content
        .replacingOccurrences(of: #"!\[[^\]]*\]\(noterepo:image:[a-f0-9]{64}\)"#, with: "[Image]", options: [.regularExpression, .caseInsensitive])
        .replacingOccurrences(of: "<br>", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return SearchResult(date: note.date, label: Day.shortTitle(note.date), excerpt: String(excerpt.prefix(120)))
    }
  }

  func focusSearch() {
    searchOpen = true
    searchFocusRequest += 1
  }

  func closeSearch() {
    query = ""
    results = []
    searchOpen = false
  }

  func jump(to date: String) {
    searchOpen = false
    feed.jump(to: date, focus: false)
  }

  func focusToday() {
    searchOpen = false
    feed.jump(to: Day.today, focus: true)
  }

  @ObservationIgnored var openedLink = false

  func open(_ url: URL) {
    guard url.scheme?.lowercased() == "noterepo" else { return }
    let host = url.host?.lowercased()
    let date = host == "today" ? Day.today : url.pathComponents.dropFirst().first ?? ""
    guard host == "today" || (host == "day" && Day.isKey(date)) else { return }
    openedLink = true
    searchOpen = false
    NSApp.activate(ignoringOtherApps: true)
    feed.jump(to: date, focus: true, animated: false)
  }
}
