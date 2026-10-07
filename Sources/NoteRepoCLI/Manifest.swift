import Foundation
import NoteRepoCore

enum Manifest {
  struct Capability: Encodable {
    let description: String
    var command: String? = nil
  }

  struct Release: Encodable {
    let version: String
    let date: String
    let changes: [String]
  }

  struct Document: Encodable {
    let name: String
    let version: String
    let summary: String
    let capabilities: [Capability]
    let changelog: [Release]
  }

  static let current = Document(
    name: "noterepo",
    version: NoteRepoVersion.current,
    summary: "Reads and writes daily notes in NoteRepo's SQLite file, with JSON on every command, while the app is open or not.",
    capabilities: [
      Capability(
        description: "Show every item on a day as JSON",
        command: "noterepo show yesterday"
      ),
      Capability(
        description: "List the days that have notes, newest first",
        command: "noterepo days --from 2026-09-01 --limit 10"
      ),
      Capability(
        description: "Search every day for text in your notes",
        command: "noterepo search accountant"
      ),
      Capability(
        description: "Add a bullet or nested item to a day",
        command: "noterepo add \"Call the accountant\" --date today"
      ),
      Capability(
        description: "Replace or append a whole day from Markdown list lines",
        command: "noterepo write yesterday --content \"- Shipped the feature\""
      ),
      Capability(
        description: "Fill several days at once from a JSON object",
        command: #"noterepo write --json --content '{"2026-09-28": "- Plan the week\n  1. Write"}'"#
      ),
      Capability(
        description: "Edit, move or remove items by their number from show",
        command: "noterepo move 2 --before 1"
      ),
      Capability(
        description: "Add a PNG, JPEG, GIF, WebP or SVG image to a day",
        command: "noterepo image ~/Desktop/receipt.png --date yesterday"
      ),
      Capability(
        description: "Back up every note and image before a demo or restore",
        command: "noterepo backup"
      ),
      Capability(
        description: "Bring NoteRepo to the front on a day",
        command: "noterepo open today"
      ),
    ],
    changelog: [
      Release(
        version: "2.3.0", date: "2026-10-07",
        changes: ["An X post gets the first line of its text. add and title treat it like any other link."]
      ),
      Release(
        version: "2.2.0", date: "2026-10-03",
        changes: ["Signed and notarized Mac app. The CLI didn't change."]
      ),
      Release(
        version: "2.1.0", date: "2026-09-30",
        changes: [
          "Several lines in one item are saved as <br>, and the CLI reads and writes them the same way.",
          "In-app updates from GitHub. The CLI didn't change.",
        ]
      ),
      Release(
        version: "2.0.0", date: "2026-09-30",
        changes: [
          "Native Swift noterepo with the same commands, options and JSON as 1.2.",
          "Reads and writes the same notes.sqlite3 file. No Node.js required.",
        ]
      ),
      Release(
        version: "1.2.0", date: "2026-09-30",
        changes: ["YouTube links in add get the video title, including Shorts and youtu.be URLs."]
      ),
      Release(
        version: "1.1.0", date: "2026-09-29",
        changes: [
          "First noterepo CLI: add, edit, move and remove items, search, write many days, backup and restore.",
          "Changes from the CLI show up in the open app within a second.",
        ]
      ),
      Release(
        version: "1.0.0", date: "2026-09-29",
        changes: ["First public release of the NoteRepo daily notes app."]
      ),
    ]
  )

  static func render(json: Bool) throws -> String {
    if json {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return String(decoding: try encoder.encode(current), as: UTF8.self)
    }

    var text = "\(current.name) \(current.version)\n\(current.summary)\n\nWhat it can do:"
    for capability in current.capabilities {
      text += "\n  \(capability.description)"
      if let command = capability.command { text += "\n    $ \(command)" }
    }
    text += "\n\nChanges:"
    for release in current.changelog {
      text += "\n  \(release.version) (\(release.date))"
      for change in release.changes { text += "\n    - \(change)" }
    }
    return text
  }
}
