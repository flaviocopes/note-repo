import Foundation
import Testing

@testable import NoteRepoCore

final class StubProtocol: URLProtocol {
  static var respond: (URL) -> (status: Int, headers: [String: String], body: String) = { _ in (404, [:], "") }
  static var requests: [URL] = []

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let url = request.url!
    StubProtocol.requests.append(url)
    let reply = StubProtocol.respond(url)
    let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}

func stub(_ respond: @escaping (URL) -> (status: Int, headers: [String: String], body: String)) {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubProtocol.self]
  LinkTitles.session = URLSession(configuration: configuration)
  StubProtocol.requests = []
  StubProtocol.respond = respond
}

func json(_ body: String, _ status: Int = 200) -> (status: Int, headers: [String: String], body: String) {
  (status, ["Content-Type": "application/json"], body)
}

func query(_ url: URL, _ name: String) -> String? {
  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

let post = "https://www.reddit.com/r/programming/comments/1d50fcu/htmx_simplicity_in_an_age_of_complicated_solutions/"
let htmxTitle = #"{"title": "htmx: Simplicity in an Age of Complicated Solutions"}"#

@Suite(.serialized) struct LinkTitleTests {
  @Test func recognizesRedditPostsCommentsAndShareLinks() {
    let link = LinkTitles.redditLink(post)
    #expect(link?.subreddit == "programming" && link?.post == "1d50fcu" && link?.comment == nil)
    #expect(LinkTitles.redditLink("\(post)l6jz9qa/?context=3")?.comment == "l6jz9qa")
    #expect(LinkTitles.redditLink("https://old.reddit.com/r/programming/comments/1d50fcu/comment/l6jz9qa/")?.comment == "l6jz9qa")
    let user = LinkTitles.redditLink("https://reddit.com/user/flaviocopes/comments/1d50fcu/a_post/")
    #expect(user?.subreddit == nil && user?.post == "1d50fcu")
    #expect(LinkTitles.redditLink("https://redd.it/1d50fcu")?.post == "1d50fcu")
    #expect(LinkTitles.redditLink("https://www.reddit.com/r/programming/s/AbCdEf1234")?.share == true)
    #expect(LinkTitles.redditLink("https://www.reddit.com/r/programming/") == nil)
    #expect(LinkTitles.redditLink("https://notreddit.com/r/programming/comments/1d50fcu/") == nil)
  }

  @Test func usesTheRedditPostTitleAndLabelsComments() async {
    stub { _ in json(htmxTitle) }
    #expect(await LinkTitles.fetch(post) == "htmx: Simplicity in an Age of Complicated Solutions")
    #expect(await LinkTitles.fetch("\(post)l6jz9qa/") == "Comment to htmx: Simplicity in an Age of Complicated Solutions")
    #expect(await LinkTitles.fetch("https://redd.it/1d50fcu") == "htmx: Simplicity in an Age of Complicated Solutions")
    #expect(query(StubProtocol.requests[1], "url") == "https://www.reddit.com/r/programming/comments/1d50fcu/")
    #expect(query(StubProtocol.requests[2], "url") == "https://www.reddit.com/r/reddit/comments/1d50fcu/")
  }

  @Test func followsRedditShareLinks() async {
    stub { url in
      url.path.contains("/s/")
        ? (301, ["Location": "\(post)l6jz9qa/?share_id=abc"], "") : json(htmxTitle)
    }
    #expect(
      await LinkTitles.fetch("https://www.reddit.com/r/programming/s/AbCdEf1234")
        == "Comment to htmx: Simplicity in an Age of Complicated Solutions")
  }

  @Test func leavesRedditLinksWithoutATitleWhenRedditDoesNotAnswer() async {
    stub { _ in json(#"{"message": "Not Found"}"#, 404) }
    #expect(await LinkTitles.fetch(post) == nil)
  }

  @Test func recognizesYouTubeVideoLinks() {
    for url in [
      "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtube.com/watch?v=dQw4w9WgXcQ&list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs&t=42s",
      "https://m.youtube.com/watch?v=dQw4w9WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://youtu.be/dQw4w9WgXcQ?si=Qm3kD8TbZ5xLr2Vn", "https://www.youtube.com/shorts/dQw4w9WgXcQ",
      "https://www.youtube.com/live/dQw4w9WgXcQ?feature=share", "https://www.youtube.com/embed/dQw4w9WgXcQ",
      "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ",
    ] {
      #expect(LinkTitles.youtubeVideo(url) == "dQw4w9WgXcQ", "\(url)")
    }
    #expect(LinkTitles.youtubeVideo("https://www.youtube.com/@flaviocopes") == nil)
    #expect(LinkTitles.youtubeVideo("https://www.youtube.com/playlist?list=PL590L5WQmH8fJ54F369BLDSqIwcs-TCfs") == nil)
    #expect(LinkTitles.youtubeVideo("https://www.youtube.com/watch?v=short") == nil)
    #expect(LinkTitles.youtubeVideo("https://notyoutube.com/watch?v=dQw4w9WgXcQ") == nil)
  }

  @Test func usesTheYouTubeVideoTitle() async {
    stub { _ in json(#"{"title": "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)"}"#) }
    #expect(
      await LinkTitles.fetch("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ")
        == "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)")
    #expect(StubProtocol.requests[0].host == "www.youtube.com" && StubProtocol.requests[0].path == "/oembed")
    #expect(query(StubProtocol.requests[0], "url") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
  }

  @Test func readsTheWatchPageWhenAVideoCannotBeEmbedded() async {
    stub { url in
      url.path == "/oembed"
        ? (401, [:], "Unauthorized")
        : (
          200, ["Content-Type": "text/html; charset=utf-8"],
          #"<head><meta property="og:title" content="A Music Video"><title>A Music Video - YouTube</title></head>"#
        )
    }
    #expect(await LinkTitles.fetch("https://youtu.be/dQw4w9WgXcQ") == "A Music Video")
    #expect(StubProtocol.requests[1].absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
  }

  @Test func leavesMissingYouTubeVideosWithoutATitle() async {
    stub { url in
      url.path == "/oembed"
        ? (400, [:], "Bad Request") : (200, ["Content-Type": "text/html"], "<head><title> - YouTube</title></head>")
    }
    #expect(await LinkTitles.fetch("https://www.youtube.com/watch?v=aaaaaaaaaaa") == nil)
  }

  @Test func usesTheFirstLineOfAnXPost() async {
    stub { url in
      guard url.host == "cdn.syndication.twimg.com" else { return (404, [:], "") }
      return json(
        #"{"__typename":"Tweet","text":"just setting up my twttr https://t.co/abc\nsecond line","display_text_range":[0,24],"entities":{"urls":[{"url":"https://t.co/abc","display_url":"flaviocopes.com"}]}}"#
      )
    }
    #expect(LinkTitles.syndicationToken("20") == "6dq")
    #expect(await LinkTitles.fetch("https://twitter.com/jack/status/20?s=20") == "just setting up my twttr")
    #expect(StubProtocol.requests[0].host == "cdn.syndication.twimg.com")
    #expect(StubProtocol.requests[0].query?.contains("id=20") == true)
    #expect(StubProtocol.requests[0].query?.contains("token=6dq") == true)
  }

  @Test func replacesAShortLinkOnTheFirstLine() async {
    stub { _ in
      json(
        #"{"__typename":"Tweet","text":"Read https://t.co/abc today","display_text_range":[0,28],"entities":{"urls":[{"url":"https://t.co/abc","display_url":"flaviocopes.com/post"}]}}"#
      )
    }
    #expect(await LinkTitles.fetch("https://x.com/flaviocopes/status/1715793063551832106") == "Read flaviocopes.com/post today")
  }

  @Test func leavesAnXPostWithoutATitleWhenXDoesNotAnswer() async {
    stub { _ in json(#"{"__typename":"TweetTombstone"}"#) }
    #expect(await LinkTitles.fetch("https://x.com/jack/status/20") == nil)
  }

  @Test func readsPageTitlesWithoutTheSiteName() async {
    stub { _ in
      (200, ["Content-Type": "text/html"], "<html><head><title>How to use SQLite &amp; Node | flaviocopes</title></head>")
    }
    #expect(await LinkTitles.fetch("https://flaviocopes.com/sqlite/") == "How to use SQLite & Node")
  }
}

@Test func formatsATitledLinkTheWayTheEditorSavesIt() {
  #expect(
    Links.linkText(url: "https://en.wikipedia.org/wiki/Rust_(programming_language)", title: "Rust [language]")
      == "[Rust (language)](https://en.wikipedia.org/wiki/Rust_%28programming_language%29) (en.wikipedia.org)")
  #expect(Links.linkText(url: "https://www.reddit.com/r/x/comments/1/", title: "Post") == "[Post](https://www.reddit.com/r/x/comments/1/) (reddit.com)")
}

@Test func keepsUntouchedLinesExactlyAsTheyWereSaved() {
  let content = "Built NoteRepo today.\n- Groceries\n\t- Apples\n1. One\n2. Two"
  #expect(Outline.serialize(Outline.parse(content)) == content)
  #expect(Outline.parse("").isEmpty)
}

@Test func describesEachItemWithItsNumberLevelListAndKind() {
  let image = String(repeating: "a", count: 64)
  let items = Outline.describe(
    Outline.parse(
      [
        "- Plan", "  1. Read [Write-Ahead Logging](https://sqlite.org/wal.html) (sqlite.org)", "",
        "- ![Screenshot](noterepo:image:\(image))", "- https://x.com/flaviocopes/status/1715793063551832106",
      ].joined(separator: "\n")))
  #expect(items.map(\.n) == [1, 2, 3, 4])
  #expect(items.map(\.level) == [0, 1, 0, 0])
  #expect(items.map(\.number) == [nil, 1, nil, nil])
  guard case .link(let links) = items[1].kind else {
    Issue.record("item 2 isn't a link")
    return
  }
  #expect(links.map(\.title) == ["Write-Ahead Logging"] && links.map(\.url) == ["https://sqlite.org/wal.html"])
  guard case .image(let id, let alt) = items[2].kind else {
    Issue.record("item 3 isn't an image")
    return
  }
  #expect(id == image && alt == "Screenshot")
  guard case .link(let links) = items[3].kind else {
    Issue.record("item 4 isn't a link")
    return
  }
  #expect(links.map(\.title) == [nil])
  #expect(links.map(\.url) == ["https://x.com/flaviocopes/status/1715793063551832106"])
}

@Test func turnsMarkdownWrittenByAgentsIntoNoteRepoLines() {
  let entries = Outline.inputEntries("* One\r\n\n    + Deep\u{200b}  \n1) First\n2. Second\n-\n\tTabbed")
  #expect(entries.map(\.depth) == [0, 2, 0, 0, 1])
  #expect(entries.map(\.ordered) == [false, false, true, true, false])
  #expect(entries.map(\.body) == ["One", "Deep", "First", "Second", "Tabbed"])
}

@Test func checksImageBytesBeforeStoringThem() {
  let png = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
  #expect(ImageData.hasSignature(png, "image/png"))
  #expect(!ImageData.hasSignature(Data("not an image".utf8), "image/png"))
  #expect(ImageData.mimeType(Data(#"<svg xmlns="http://www.w3.org/2000/svg"></svg>"#.utf8)) == "image/svg+xml")
  #expect(ImageData.mimeType(Data("<svg><script>alert(1)</script></svg>".utf8)) == nil)
}
