import Foundation
import Testing

@testable import NoteRepoCore

@Test func parsesListLines() {
  #expect(Outline.parseLine("  1. Write", previousDepth: 0) == OutlineEntry(depth: 1, ordered: true, start: 1, body: "Write"))
  #expect(Outline.parseLine("\t- Apples", previousDepth: 0) == OutlineEntry(depth: 1, ordered: false, body: "Apples"))
  #expect(Outline.parseLine("      - Deep", previousDepth: 0).depth == 1)
  #expect(Outline.parseLine("1.foo", previousDepth: -1) == OutlineEntry(depth: 0, ordered: false, body: "1.foo"))
  #expect(Outline.parseLine("-", previousDepth: -1) == OutlineEntry(depth: 0, ordered: false, body: ""))
  #expect(Outline.parseLine("Built it", previousDepth: -1).body == "Built it")
}

@Test func renumbersNumberedLists() {
  var entries = Outline.parse("- Plan\n  1. Write\n  2. Test")
  entries.insert(OutlineEntry(depth: 1, ordered: true, body: "Outline"), at: 1)
  #expect(Outline.serialize(entries) == "- Plan\n  1. Outline\n  2. Write\n  3. Test")
}

@Test func formatsEmptyItems() {
  #expect(Outline.format(OutlineEntry(depth: 0, ordered: false, body: " ")) == "")
  #expect(Outline.format(OutlineEntry(depth: 2, ordered: false, body: "")) == "    -")
  #expect(Outline.format(OutlineEntry(depth: 0, ordered: true, start: 3, body: "Three  ")) == "3. Three")
}

@Test func keepsAStarOnTheItem() {
  let image = String(repeating: "a", count: 64)
  let items = Outline.describe(
    Outline.parse("- ★ Buy milk\n- Bread\n- ★ ![Shot](noterepo:image:\(image))"))
  #expect(items[0].starred && items[0].text == "Buy milk")
  #expect(!items[1].starred && items[1].text == "Bread")
  #expect(items[2].starred && items[2].text == "![Shot](noterepo:image:\(image))")
  guard case .image(let id, let alt) = items[2].kind else {
    Issue.record("a starred image is still an image")
    return
  }
  #expect(id == image && alt == "Shot")
  #expect(Outline.normalized(Outline.parse("- ★ Buy milk")) == "- ★ Buy milk")
  #expect(Outline.withStar("", starred: true) == "★")
  #expect(Outline.splitStar("★") == (starred: true, text: ""))
  #expect(Outline.splitStar("Buy milk") == (starred: false, text: "Buy milk"))
}

@Test func detectsNoteContent() {
  #expect(!Outline.hasContent(" \n\t "))
  #expect(!Outline.hasContent("- "))
  #expect(!Outline.hasContent("1. "))
  #expect(Outline.hasContent("- Buy milk"))
}

@Test func mergesOutsideChanges() {
  let base = "- A\n- B"
  #expect(Outline.merge(base: base, mine: "- A\n- B\n- Mine", theirs: "- A\n- B\n- Theirs") == "- A\n- B\n- Mine\n- Theirs")
  #expect(Outline.merge(base: base, mine: "- A edited\n- B", theirs: "- A\n- B changed") == "- A edited\n- B changed")
  #expect(Outline.merge(base: base, mine: "- A\n- B\n- Mine", theirs: "- B") == "- B\n- Mine")
  #expect(Outline.merge(base: base, mine: "- A mine\n- B", theirs: "- A theirs\n- B") == "- A mine\n- A theirs\n- B")
  #expect(Outline.merge(base: base, mine: base, theirs: "- Theirs") == "- Theirs")
  #expect(Outline.merge(base: base, mine: "- Mine", theirs: base) == "- Mine")
  #expect(Outline.merge(base: "", mine: "- Mine", theirs: "- Theirs") == "- Mine\n- Theirs")
}

@Test func splitsInlineLinksAndImages() {
  let id = String(repeating: "a", count: 64)
  let tokens = Links.tokens("Read [WAL](https://sqlite.org/wal.html) (sqlite.org), see https://flaviocopes.com. ![Shot](noterepo:image:\(id))")
  #expect(
    tokens == [
      .text("Read "), .link(title: "WAL", url: "https://sqlite.org/wal.html"), .text(" (sqlite.org), see "),
      .link(title: nil, url: "https://flaviocopes.com"), .text("."), .text(" "), .image(id: id, alt: "Shot"),
    ])
}

@Test func recognizesSpecialLinks() {
  #expect(LinkTitles.xPost("https://x.com/flaviocopes/status/1715793063551832106") == "1715793063551832106")
  #expect(LinkTitles.xPost("https://twitter.com/flaviocopes/status/1715793063551832106?s=20") == "1715793063551832106")
  #expect(LinkTitles.xPost("https://x.com/flaviocopes") == nil)
  #expect(LinkTitles.youtubeVideo("https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
  #expect(LinkTitles.youtubeVideo("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=4") == "dQw4w9WgXcQ")
  #expect(LinkTitles.youtubeVideo("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
  #expect(LinkTitles.redditLink("https://www.reddit.com/r/swift/comments/abc123/some_title/")?.subreddit == "swift")
  #expect(Links.linkText(url: "https://www.flaviocopes.com/a(b)", title: "A [new] post") == "[A (new) post](https://www.flaviocopes.com/a%28b%29) (flaviocopes.com)")
}

@Test func extractsPageTitles() {
  let url = URL(string: "https://flaviocopes.com/sqlite/")!
  #expect(LinkTitles.extractPageTitle("<title>How to use SQLite &amp; Node | flaviocopes</title>", pageURL: url) == "How to use SQLite & Node")
  #expect(LinkTitles.extractPageTitle(#"<meta property="og:title" content="Plan mode is dead">"#, pageURL: url) == "Plan mode is dead")
}

@Test func formatsDayTitles() {
  #expect(Day.title("2026-08-01") == "Sat, August 1st, 2026")
  #expect(Day.title("2026-08-02") == "Sun, August 2nd, 2026")
  #expect(Day.title("2026-08-11") == "Tue, August 11th, 2026")
  #expect(Day.title("2026-08-21") == "Fri, August 21st, 2026")
  #expect(Day.shortTitle("2026-09-30") == "Wed, Sep 30, 2026")
  #expect(!Day.isKey("2026-02-30"))
}

@Test func savesAndMergesNotes() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try NoteStore(url: folder.appendingPathComponent("notes.sqlite3"))
  try store.save("2026-09-28", "- A\n- B")
  try store.save("2026-09-28", "- A\n- B\n- Theirs")
  let merged = try store.save("2026-09-28", "- A\n- B\n- Mine", base: "- A\n- B")
  #expect(merged.content == "- A\n- B\n- Mine\n- Theirs")
  #expect(try store.has("2026-09-28"))
  #expect(try store.notesBefore("2026-09-30", limit: 7).map(\.date) == ["2026-09-28"])
  #expect(try store.search("mine").count == 1)

  let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
  let id = try store.saveImage(data: png, mimeType: "image/png", fileName: "pixel.png", width: 1, height: 1)
  #expect(id.count == 64)
  #expect(try store.image(id)?.data == png)
}
