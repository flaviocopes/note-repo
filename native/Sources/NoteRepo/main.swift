import AppKit
import NoteRepoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static var model: AppModel!

  func applicationDidFinishLaunching(_ notification: Notification) {
    let model = AppDelegate.model!
    if CommandLine.arguments.contains("--round-trip") { SelfTest.roundTrip(model.store) }
    model.feed.load(anchor: Day.today)
    if CommandLine.arguments.contains("--automation") { Automation.start(model) }
    if CommandLine.arguments.contains("--self-test") {
      Task { await SelfTest.run(model) }
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.feed.jump(to: Day.today, focus: true, animated: false) }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    AppDelegate.model?.feed.flushSaves()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct NoteRepoApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  private let model = AppDelegate.model!

  var body: some Scene {
    Window("NoteRepo", id: "main") {
      ContentView(model: model)
    }
    .windowStyle(.hiddenTitleBar)
    .defaultSize(width: 1240, height: 790)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(replacing: .textEditing) {}
      CommandMenu("Go") {
        Button("Today") { model.focusToday() }
          .keyboardShortcut("d")
        Button("Search") { model.focusSearch() }
          .keyboardShortcut("f")
        Button("Search Notes") { model.focusSearch() }
          .keyboardShortcut("k")
        Divider()
        Button("Previous Day") { model.feed.moveDay(-1) }
          .keyboardShortcut(.upArrow, modifiers: .option)
        Button("Next Day") { model.feed.moveDay(1) }
          .keyboardShortcut(.downArrow, modifiers: .option)
      }
    }
  }
}

MainActor.assumeIsolated {
  let url = AppModel.dataURL()
  if CommandLine.arguments.contains("--self-test") && url == NoteStore.defaultURL {
    FileHandle.standardError.write(Data("The self-test needs --user-data-dir with a temporary folder\n".utf8))
    exit(2)
  }
  do {
    AppDelegate.model = AppModel(store: try NoteStore(url: url))
  } catch {
    let alert = NSAlert()
    alert.messageText = "NoteRepo can't open its notes"
    alert.informativeText = "\(url.path)\n\(error.localizedDescription)"
    alert.runModal()
    exit(1)
  }
}
NoteRepoApp.main()
