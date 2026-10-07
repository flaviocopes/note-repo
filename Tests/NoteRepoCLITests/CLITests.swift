import Foundation
import NoteRepoCore
import Testing

@testable import NoteRepoCLI

let pixelPNG = Data(
  base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

final class Notebook {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noterepo-cli-\(UUID().uuidString)")

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func run(_ arguments: [String], stdin: String = "") async -> (code: Int32, output: JSON?, error: String?, text: String) {
    let context = CLIContext(
      arguments: ["--data-dir", directory.appendingPathComponent("data").path] + arguments,
      environment: ["HOME": directory.path], currentDirectory: directory.path, readStdin: { stdin },
      runningApp: { nil }, open: { _ in false })
    let result = await CLI.run(context)
    let output = result.stdout.isEmpty ? nil : try? JSON.parse(result.stdout)
    let error = result.stderr.isEmpty ? nil : (try? JSON.parse(result.stderr))?["error"]?.string
    return (result.code, output, error, result.stdout)
  }

  func ok(_ arguments: String..., stdin: String = "") async throws -> JSON {
    let result = await run(arguments, stdin: stdin)
    #expect(result.error == nil, "\(arguments): \(result.error ?? "")")
    return try #require(result.output)
  }
}

func content(_ day: JSON) -> String? { day["content"]?.string }

@Test func addsEditsMovesAndRemovesItemsLikeAPersonWould() async throws {
  let book = try Notebook()
  _ = try await book.ok("add", "Plan for the week", "--date", "2026-09-28")
  _ = try await book.ok("add", "Write the CLI", "--date", "2026-09-28", "--after", "1", "--level", "1", "--numbered")
  _ = try await book.ok("add", "Test it", "--date", "2026-09-28", "--after", "2")
  _ = try await book.ok("add", "Outline it", "--date", "2026-09-28", "--before", "2")
  var day = try await book.ok("add", "Gym", "--date", "2026-09-28")
  #expect(content(day) == "- Plan for the week\n  1. Outline it\n  2. Write the CLI\n  3. Test it\n- Gym")
  #expect(day["title"]?.string == "Mon, September 28th, 2026")
  let items = day["items"]!.array.map { [$0["n"]?.int, $0["level"]?.int, $0["number"]?.int] }
  #expect(items == [[1, 0, nil], [2, 1, 1], [3, 1, 2], [4, 1, 3], [5, 0, nil]])
  #expect(day["items"]![1]!["list"]?.string == "numbered")

  day = try await book.ok("edit", "3", "Write the companion CLI", "--date", "2026-09-28")
  #expect(content(day)?.contains("2. Write the companion CLI") == true)

  day = try await book.ok("remove", "2", "--date", "2026-09-28")
  #expect(content(day) == "- Plan for the week\n  1. Write the companion CLI\n  2. Test it\n- Gym")

  day = try await book.ok("move", "4", "--date", "2026-09-28", "--before", "1")
  #expect(content(day) == "- Gym\n- Plan for the week\n  1. Write the companion CLI\n  2. Test it")

  day = try await book.ok("edit", "4", "--date", "2026-09-28", "--level", "0", "--bullet")
  #expect(content(day) == "- Gym\n- Plan for the week\n  1. Write the companion CLI\n- Test it")

  let moved = try await book.ok("move", "2", "--date", "2026-09-28", "--to", "2026-09-27")
  #expect(content(moved["from"]!) == "- Gym\n- Test it")
  #expect(content(moved["to"]!) == "- Plan for the week\n  1. Write the companion CLI")
}

@Test func acceptsMarkdownListMarkersAndPipedText() async throws {
  let book = try Notebook()
  _ = try await book.ok("add", "- Buy milk", "--date", "2026-09-24")
  _ = try await book.ok("add", "1. Call the bank", "--date", "2026-09-24")
  let day = try await book.ok("write", "2026-09-24", "--append", "--content", "- Read later")
  #expect(content(day) == "- Buy milk\n1. Call the bank\n- Read later")

  let piped = try await book.ok("add", "-", "--date", "2026-09-24", stdin: "Piped from another tool\n")
  #expect(piped["items"]!.array.last?["text"]?.string == "Piped from another tool")
}

@Test func keepsALineBreakInsideOneItem() async throws {
  let book = try Notebook()
  let day = try await book.ok("add", "Groceries<br>milk, eggs", "--date", "2026-09-24")
  #expect(content(day) == "- Groceries<br>milk, eggs")
  #expect(day["items"]!.array.map { $0["text"]?.string } == ["Groceries<br>milk, eggs"])
}

@Test func writesManyDaysAtOnceAndListsThem() async throws {
  let book = try Notebook()
  let json = #"{"2026-09-25": "* Newsletter sent\n    - Deep\n1) One\n2) Two", "2026-09-26": ["- https://news.ycombinator.com/item?id=49854875"]}"#
  let written = try await book.ok("write", "--json", "--raw", "--content", json)
  #expect(written["days"]!.array.map { [$0["date"]?.string, $0["items"]?.int.map(String.init)] } == [
    ["2026-09-25", "4"], ["2026-09-26", "1"],
  ])
  #expect(content(try await book.ok("show", "2026-09-25")) == "- Newsletter sent\n  - Deep\n1. One\n2. Two")

  let appended = try await book.ok("write", "2026-09-26", "--append", "--content", "- Read later")
  #expect(content(appended) == "- https://news.ycombinator.com/item?id=49854875\n- Read later")

  let days = try await book.ok("days")
  #expect(days["days"]!.array.map { $0["date"]?.string } == ["2026-09-26", "2026-09-25"])
  #expect(days["days"]!.array.map { $0["items"]?.int } == [2, 4])

  let search = try await book.ok("search", "newsletter")
  #expect(search["results"]!.array.map { $0["date"]?.string } == ["2026-09-25"])
  #expect(search["results"]![0]!["items"]!.array.map { $0["n"]?.int } == [1])

  let cleared = await book.run(["clear", "2026-09-26"])
  #expect(cleared.text == "{\n  \"date\": \"2026-09-26\",\n  \"cleared\": true\n}\n")
  #expect(try await book.ok("days")["days"]!.array.map { $0["date"]?.string } == ["2026-09-25"])
}

final class XPostStub: URLProtocol {
  static var body = ""

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(XPostStub.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

@Test func addsImagesAndTitlesXPosts() async throws {
  let book = try Notebook()
  let image = book.directory.appendingPathComponent("screenshot.png")
  try pixelPNG.write(to: image)

  var day = try await book.ok("image", image.path)
  #expect(day["date"]?.string == Day.today)
  #expect(day["items"]![0]!["kind"]?.string == "image")
  #expect(day["items"]![0]!["image"]?["alt"]?.string == "screenshot.png")

  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [XPostStub.self]
  let previous = LinkTitles.session
  LinkTitles.session = URLSession(configuration: configuration)
  defer { LinkTitles.session = previous }
  XPostStub.body =
    #"{"__typename":"Tweet","text":"just setting up my twttr\nsecond line","display_text_range":[0,31]}"#

  let post = "https://x.com/jack/status/20"
  day = try await book.ok("add", post)
  #expect(day["items"]![1]!["kind"]?.string == "link")
  #expect(day["items"]![1]!["text"]?.string == "[just setting up my twttr](\(post)) (x.com)")

  let title = try await book.ok("title", post)
  #expect(title["title"]?.string == "just setting up my twttr")
  #expect(title["text"]?.string == "[just setting up my twttr](\(post)) (x.com)")
  #expect(title["preview"] == nil)
  #expect(try await book.ok("info")["images"]?.int == 1)
}

@Test func explainsMistakesWithAJSONErrorAndAnExitCode() async throws {
  let book = try Notebook()
  try Data("not an image".utf8).write(to: book.directory.appendingPathComponent("fake.png"))

  let future = await book.run(["add", "Tomorrow", "--date", "2999-01-01"])
  #expect(future.code == 1)
  #expect(future.error?.contains("in the future") == true)

  let missing = await book.run(["edit", "3", "Nope"])
  #expect(missing.code == 1)
  #expect(missing.error?.contains("Item 3 doesn't exist") == true)

  #expect(await book.run(["add", "Too deep", "--level", "2"]).error?.contains("deepest level allowed") == true)
  #expect(await book.run(["image", "fake.png"]).error?.contains("isn't a PNG") == true)
  #expect(await book.run(["frobnicate"]).code == 2)
  #expect(await book.run(["add", "x", "--nope"]).code == 2)
  #expect(await book.run(["write", "2026-09-01", "--content", "  "]).code == 2)
  #expect(await book.run(["reset"]).code == 2)
}

@Test func backsUpResetsAndRestoresTheNotebook() async throws {
  let book = try Notebook()
  _ = try await book.ok("add", "Keep me", "--date", "2026-09-20")

  let saved = try await book.ok("backup")
  #expect(saved["days"]?.int == 1)
  #expect(saved["sha256"]?.string?.count == 64)

  let reset = try await book.ok("reset", "--yes")
  #expect(reset["days"]?.int == 0)
  #expect(reset["backup"]?["path"]?.string?.hasSuffix("before-reset") == true)
  _ = try await book.ok("add", "Demo note", "--date", "2026-09-21")

  let restored = try await book.ok("restore", saved["path"]!.string!, "--yes")
  #expect(restored["restored"]?["days"]?.int == 1)
  #expect(restored["backup"]?["path"]?.string?.hasSuffix("before-restore") == true)
  #expect(content(try await book.ok("show", "2026-09-20")) == "- Keep me")
  #expect(content(try await book.ok("show", "2026-09-21")) == "")

  try Data("nope".utf8).write(to: book.directory.appendingPathComponent("not-a-database.sqlite3"))
  let broken = await book.run(["restore", "not-a-database.sqlite3", "--yes"])
  #expect(broken.error?.contains("isn't a NoteRepo database") == true)
  #expect(content(try await book.ok("show", "2026-09-20")) == "- Keep me")
}

@Test func printsHelpAndTheVersion() async throws {
  let book = try Notebook()
  #expect(await book.run(["--version"]).text == "noterepo \(NoteRepoVersion.current)\n")
  let help = await book.run(["help"])
  #expect(help.text.hasPrefix("noterepo \(NoteRepoVersion.current), the NoteRepo companion CLI for agents\n"))
  #expect(help.text.contains(#"{"2026-09-28": "- Plan\n  1. Write"}"#))
  #expect(help.text.contains("capabilities"))
}

@Test func capabilitiesManifestEncodesForAgents() async throws {
  let book = try Notebook()
  let json = await book.run(["capabilities", "--json"])
  #expect(json.error == nil)
  let parsed = try #require(json.output)
  #expect(parsed["name"]?.string == "noterepo")
  #expect(parsed["version"]?.string == NoteRepoVersion.current)
  #expect(parsed["summary"]?.string?.isEmpty == false)
  #expect(parsed["capabilities"]!.array.count >= 4)
  #expect(parsed["changelog"]!.array.isEmpty == false)

  let text = await book.run(["capabilities"])
  #expect(text.error == nil)
  #expect(text.text.hasPrefix("noterepo \(NoteRepoVersion.current)\n"))
  #expect(text.text.contains("What it can do:"))
}

@Test func writesJSONLikeJavaScript() throws {
  let value = JSON.object([
    "text": .string("Tab\there \"quoted\" \\ \u{01} é 😀"), "empty": .array([]), "nested": .object([:]),
    "number": .int(3), "skipped": nil,
  ])
  #expect(
    value.pretty
      == "{\n  \"text\": \"Tab\\there \\\"quoted\\\" \\\\ \\u0001 é 😀\",\n  \"empty\": [],\n  \"nested\": {},\n  \"number\": 3\n}")
  #expect(JSON.object(["error": .string("Nope")]).compact == #"{"error":"Nope"}"#)
  #expect(try JSON.parse(#"{"b": 1, "a": [true, null, "x\u00e9"]}"#).fields.map(\.key) == ["b", "a"])
}
