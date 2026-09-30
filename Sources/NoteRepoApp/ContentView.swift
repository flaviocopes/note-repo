import AppKit
import NoteRepoCore
import SwiftUI

struct ContentView: View {
  let model: AppModel

  var body: some View {
    HStack(spacing: 0) {
      SidebarView(model: model)
        .frame(width: 183)
      Rectangle()
        .fill(Color(Theme.divider))
        .frame(width: 1)
      FeedRepresentable(feed: model.feed)
    }
    .background(Color(Theme.background))
    .ignoresSafeArea()
    .frame(minWidth: 640, minHeight: 480)
    .background(WindowConfigurator())
    .onOpenURL { model.open($0) }
  }
}

struct FeedRepresentable: NSViewRepresentable {
  let feed: FeedController

  func makeNSView(context: Context) -> NSScrollView { feed.scrollView }
  func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

struct SidebarView: View {
  @Bindable var model: AppModel
  @FocusState private var searchFocused: Bool

  private var isToday: Bool { model.activeDate == Day.today }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Button {
        model.focusToday()
      } label: {
        Text("Today")
          .font(Font(Theme.mono(12)))
          .foregroundStyle(Color(isToday ? Theme.text : Theme.muted))
          .padding(.vertical, 5)
          .padding(.horizontal, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 5).fill(Color(isToday ? Theme.field : .clear)))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Today (⌘D)")

      searchField
        .zIndex(1)

      Spacer(minLength: 0)

      if let error = model.saveError {
        Text(error)
          .font(Font(Theme.mono(10)))
          .foregroundStyle(Color(Theme.red))
          .padding(.horizontal, 8)
      }
    }
    .padding(EdgeInsets(top: 52, leading: 14, bottom: 14, trailing: 14))
    .onChange(of: model.searchFocusRequest) { searchFocused = true }
  }

  private var searchField: some View {
    TextField("", text: $model.query, prompt: Text("Search").foregroundStyle(Color(Theme.faint)))
      .textFieldStyle(.plain)
      .font(Font(Theme.mono(11)))
      .foregroundStyle(Color(Theme.text))
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(RoundedRectangle(cornerRadius: 5).fill(Color(Theme.field)))
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .strokeBorder(Color(Theme.accent).opacity(searchFocused ? 0.5 : 0), lineWidth: 1)
      )
      .focused($searchFocused)
      .help("Search (⌘F)")
      .onChange(of: searchFocused) { if searchFocused { model.searchOpen = true } }
      .onChange(of: model.query) {
        model.searchOpen = true
        model.queryChanged()
      }
      .onSubmit { model.runSearch() }
      .onExitCommand { model.closeSearch() }
      .overlay(alignment: .topLeading) {
        if model.searchOpen && !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
          SearchResultsView(model: model)
            .offset(y: 34)
        }
      }
  }
}

struct SearchResultsView: View {
  let model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if model.results.isEmpty {
          Text("No matches")
            .font(Font(Theme.mono(10)))
            .foregroundStyle(Color(Theme.muted))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(model.results) { result in
          SearchResultRow(result: result) { model.jump(to: result.date) }
        }
      }
      .padding(4)
    }
    .scrollIndicators(.never)
    .frame(width: 156)
    .frame(maxHeight: 260)
    .fixedSize(horizontal: false, vertical: true)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(Theme.popover)))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(Theme.divider), lineWidth: 1))
    .shadow(color: Color(Theme.shadow), radius: 15, y: 12)
  }
}

struct SearchResultRow: View {
  let result: SearchResult
  let action: () -> Void
  @State private var hovered = false

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 3) {
        Text(result.label)
          .font(Font(Theme.mono(10, .semibold)))
          .foregroundStyle(Color(Theme.text))
        Text(result.excerpt)
          .font(Font(Theme.mono(10)))
          .foregroundStyle(Color(Theme.muted))
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.vertical, 7)
      .padding(.horizontal, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 4).fill(Color(hovered ? Theme.field : .clear)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
  }
}

struct WindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { WindowHook() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  final class WindowHook: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      window.backgroundColor = Theme.background
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.isMovableByWindowBackground = false
      window.tabbingMode = .disallowed
      for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(placeTrafficLights), name: name, object: window)
      }
      placeTrafficLights()
    }

    override func layout() {
      super.layout()
      placeTrafficLights()
    }

    @objc private func placeTrafficLights() {
      guard let window, !window.styleMask.contains(.fullScreen),
        let close = window.standardWindowButton(.closeButton),
        let minimize = window.standardWindowButton(.miniaturizeButton),
        let zoom = window.standardWindowButton(.zoomButton),
        let titlebar = close.superview, let container = titlebar.superview
      else { return }
      let height: CGFloat = 38
      container.frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
      titlebar.frame = container.bounds
      let spacing = max(20, minimize.frame.minX - close.frame.minX)
      for (index, button) in [close, minimize, zoom].enumerated() {
        button.setFrameOrigin(NSPoint(x: 16 + CGFloat(index) * spacing, y: height - 16 - button.frame.height))
      }
    }
  }
}
