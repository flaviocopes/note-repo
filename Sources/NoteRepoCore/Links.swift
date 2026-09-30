import Foundation

extension NSRegularExpression {
  public convenience init(_ pattern: String, _ options: Options = []) {
    try! self.init(pattern: pattern, options: options)
  }

  public func groups(in value: String) -> [String?]? {
    let range = NSRange(value.startIndex..., in: value)
    guard let match = firstMatch(in: value, range: range) else { return nil }
    return (0..<match.numberOfRanges).map { index in
      Range(match.range(at: index), in: value).map { String(value[$0]) }
    }
  }

  public func matches(_ value: String) -> Bool {
    firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
  }
}

public struct Tweet: Equatable, Sendable {
  public let url: String
  public let user: String
  public let id: String
}

public enum InlineToken: Equatable, Sendable {
  case text(String)
  case link(title: String?, url: String)
  case image(id: String, alt: String)
}

public enum Links {
  static let inline = NSRegularExpression(
    #"!\[([^\]]*)\]\(noterepo:image:([a-f0-9]{64})\)|\[([^\]]+)\]\((https?://[^\s)]+)\)|(https?://[^\s<>()\]]+)"#,
    .caseInsensitive)
  static let trailingPunctuation = NSRegularExpression(#"[.,;!?]+$"#)
  static let tweetPattern = NSRegularExpression(
    #"^https?://(?:www\.)?(?:x\.com|twitter\.com)/([a-z0-9_]+)/status/(\d+)(?:[/?#].*)?$"#,
    .caseInsensitive)
  static let imageItem = NSRegularExpression(#"^!\[([^\]]*)\]\(noterepo:image:([a-f0-9]{64})\)$"#, .caseInsensitive)

  public static func tokens(_ body: String) -> [InlineToken] {
    var tokens: [InlineToken] = []
    let source = body as NSString
    var cursor = 0
    for match in inline.matches(in: body, range: NSRange(location: 0, length: source.length)) {
      if match.range.location > cursor {
        tokens.append(.text(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
      }
      cursor = match.range.location + match.range.length
      let group = { (index: Int) -> String? in
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : source.substring(with: range)
      }
      if let id = group(2) {
        tokens.append(.image(id: id.lowercased(), alt: group(1) ?? ""))
      } else if let url = group(4) {
        tokens.append(.link(title: group(3), url: url))
      } else if let raw = group(5) {
        let url = trimTrailingPunctuation(raw)
        tokens.append(.link(title: nil, url: url))
        if url.count < raw.count { tokens.append(.text(String(raw.dropFirst(url.count)))) }
      }
    }
    if cursor < source.length { tokens.append(.text(source.substring(from: cursor))) }
    return tokens
  }

  static func trimTrailingPunctuation(_ value: String) -> String {
    trailingPunctuation.stringByReplacingMatches(
      in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
  }

  public static func tweet(_ value: String) -> Tweet? {
    let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let groups = tweetPattern.groups(in: url), let user = groups[1], let id = groups[2] else { return nil }
    return Tweet(url: url, user: user, id: id)
  }

  public static func imageItem(_ body: String) -> (id: String, alt: String)? {
    let value = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let groups = imageItem.groups(in: value), let id = groups[2] else { return nil }
    return (id.lowercased(), groups[1] ?? "")
  }

  public static func domain(_ url: String) -> String {
    let host = URL(string: url)?.host?.lowercased() ?? url
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  public static func escapeURL(_ url: String) -> String {
    url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
  }

  public static func cleanTitle(_ title: String) -> String {
    title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
  }

  public static func linkText(url: String, title: String) -> String {
    let url = escapeURL(url)
    return "[\(cleanTitle(title))](\(url)) (\(domain(url)))"
  }
}

public enum LinkTitles {
  public static var session = URLSession.shared
  static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
  static let timeout: TimeInterval = 8
  static let maxPageBytes = 1_000_000

  static let entities: [String: String] = [
    "amp": "&", "apos": "'", "bull": "•", "gt": ">", "hellip": "…", "laquo": "«", "ldquo": "“",
    "lsquo": "‘", "lt": "<", "mdash": "—", "middot": "·", "nbsp": " ", "ndash": "–", "quot": "\"",
    "raquo": "»", "rdquo": "”", "rsquo": "’",
  ]
  static let entityPattern = NSRegularExpression(#"&(?:#(\d+)|#x([\da-f]+)|([a-z]+));"#, .caseInsensitive)
  static let metaPattern = NSRegularExpression(#"<meta\b(?:"[^"]*"|'[^']*'|[^'">])*>"#, .caseInsensitive)
  static let attributePattern = NSRegularExpression(#"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
  static let titlePattern = NSRegularExpression(#"<title\b[^>]*>([\s\S]*?)</title>"#, .caseInsensitive)
  static let siteSuffix = NSRegularExpression(#"^(.*\S)\s+([|\-–—·•])\s+(\S.*)$"#)
  static let whitespace = NSRegularExpression(#"\s+"#)
  static let headerCharset = NSRegularExpression(#"charset=["']?([\w-]+)"#, .caseInsensitive)
  static let metaCharset = NSRegularExpression(#"<meta[^>]+charset=["']?([\w-]+)"#, .caseInsensitive)
  static let redditHost = NSRegularExpression(#"^(?:(?:www|old|new|np|m|sh|i)\.)?reddit\.com$"#, .caseInsensitive)
  static let redditID = NSRegularExpression(#"^[a-z0-9]+$"#, .caseInsensitive)
  static let youtubeHost = NSRegularExpression(#"^(?:(?:www|m|music)\.)?youtube(?:-nocookie)?\.com$"#, .caseInsensitive)
  static let youtubePath = NSRegularExpression(#"^(?:shorts|live|embed|v)$"#, .caseInsensitive)
  static let youtubeID = NSRegularExpression(#"^[\w-]{11}$"#)

  public static func fetch(_ value: String) async -> String? {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else { return nil }
    if let video = youtubeVideo(url.absoluteString) { return await youtubeTitle(video) }
    if redditLink(url.absoluteString) != nil { return await redditTitle(url.absoluteString) }
    return await pageTitle(url)
  }

  static func request(_ url: URL, accept: String) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    return request
  }

  static func decodeEntities(_ value: String) -> String {
    let source = value as NSString
    var result = ""
    var cursor = 0
    for match in entityPattern.matches(in: value, range: NSRange(location: 0, length: source.length)) {
      result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      cursor = match.range.location + match.range.length
      let entity = source.substring(with: match.range)
      let group = { (index: Int) -> String? in
        let range = match.range(at: index)
        return range.location == NSNotFound ? nil : source.substring(with: range)
      }
      if let name = group(3) {
        result += entities[name.lowercased()] ?? entity
      } else if let code = group(1).flatMap({ Int($0) }) ?? group(2).flatMap({ Int($0, radix: 16) }),
        code > 0, let scalar = Unicode.Scalar(code)
      {
        result.unicodeScalars.append(scalar)
      } else {
        result += entity
      }
    }
    return result + source.substring(from: cursor)
  }

  static func cleanPageText(_ value: String) -> String {
    let decoded = decodeEntities(value)
    return whitespace.stringByReplacingMatches(
      in: decoded, range: NSRange(decoded.startIndex..., in: decoded), withTemplate: " "
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func metaTags(_ html: String) -> [String: String] {
    var tags: [String: String] = [:]
    let source = html as NSString
    for tagMatch in metaPattern.matches(in: html, range: NSRange(location: 0, length: source.length)) {
      let tag = source.substring(with: tagMatch.range)
      let tagSource = tag as NSString
      var attributes: [String: String] = [:]
      for match in attributePattern.matches(in: tag, range: NSRange(location: 0, length: tagSource.length)) {
        let name = tagSource.substring(with: match.range(at: 1)).lowercased()
        let value = (2...4).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
        if let value { attributes[name] = tagSource.substring(with: value) }
      }
      let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
      if !key.isEmpty, let content = attributes["content"], !content.isEmpty, tags[key] == nil { tags[key] = content }
    }
    return tags
  }

  static func compactName(_ value: String) -> String {
    value.lowercased().filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
  }

  static func withoutSiteName(_ title: String, siteName: String, hostname: String) -> String {
    guard let groups = siteSuffix.groups(in: title), let rest = groups[1], let separator = groups[2],
      let suffix = groups[3]
    else { return title }
    let suffixName = compactName(suffix)
    let hostParts = hostname.split(separator: ".").dropLast().map(String.init)
    let isSiteName =
      suffixName == compactName(siteName) || hostParts.contains(suffixName)
      || (separator == "|" && suffix.split(separator: " ", omittingEmptySubsequences: false).count <= 4)
    return !suffixName.isEmpty && isSiteName ? rest : title
  }

  public static func extractPageTitle(_ html: String, pageURL: URL) -> String? {
    let meta = metaTags(html)
    let raw = meta["og:title"] ?? meta["twitter:title"] ?? titlePattern.groups(in: html)?[1] ?? ""
    let title = cleanPageText(raw)
    guard !title.isEmpty else { return nil }
    let siteName = cleanPageText(meta["og:site_name"] ?? meta["application-name"] ?? "")
    return String(withoutSiteName(title, siteName: siteName, hostname: pageURL.host ?? "").prefix(300))
  }

  static func encoding(named name: String?) -> String.Encoding? {
    guard let name else { return nil }
    let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
    guard cf != kCFStringEncodingInvalidId else { return nil }
    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
  }

  static func pageTitle(_ url: URL) async -> String? {
    guard
      let (bytes, response) = try? await session.bytes(
        for: request(url, accept: "text/html,application/xhtml+xml")),
      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("html")
    else { return nil }

    var data = Data()
    var checked = 0
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count >= maxPageBytes { break }
        if data.count - checked >= 2048 {
          checked = data.count
          if String(decoding: data.suffix(2056), as: UTF8.self).lowercased().contains("</head") { break }
        }
      }
    } catch {
      if data.isEmpty { return nil }
    }

    let latin = String(data: data, encoding: .isoLatin1) ?? ""
    let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
    let charset = headerCharset.groups(in: contentType)?[1] ?? metaCharset.groups(in: latin)?[1]
    let html =
      encoding(named: charset).flatMap { String(data: data, encoding: $0) } ?? String(decoding: data, as: UTF8.self)
    return extractPageTitle(html, pageURL: http.url ?? url)
  }

  struct RedditLink {
    var share = false
    var subreddit: String?
    var post = ""
    var comment: String?
  }

  static func pathParts(_ url: URL) -> [String] {
    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path)
      .split(separator: "/").map(String.init)
  }

  static func redditLink(_ value: String) -> RedditLink? {
    guard let url = URL(string: value), let host = url.host?.lowercased() else { return nil }
    let parts = pathParts(url)
    if host == "redd.it" {
      return parts.count == 1 && redditID.matches(parts[0]) ? RedditLink(post: parts[0]) : nil
    }
    guard redditHost.matches(host) else { return nil }
    if let first = parts.first, ["r", "u", "user"].contains(first.lowercased()), parts.count > 3, parts[2] == "s",
      !parts[3].isEmpty
    {
      return RedditLink(share: true)
    }
    guard let index = parts.firstIndex(of: "comments") else { return nil }
    let post = parts.count > index + 1 ? parts[index + 1] : ""
    guard redditID.matches(post) else { return nil }
    let comment = parts.count > index + 3 ? parts[index + 3] : ""
    return RedditLink(
      subreddit: parts.first?.lowercased() == "r" && index == 2 ? parts[1] : nil,
      post: post,
      comment: redditID.matches(comment) ? comment : nil)
  }

  final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest
    ) async -> URLRequest? { nil }
  }

  static func resolveRedditShare(_ value: String) async -> RedditLink? {
    guard var url = URL(string: value) else { return nil }
    for _ in 0..<5 {
      guard
        let (_, response) = try? await session.data(
          for: request(url, accept: "text/html"), delegate: NoRedirects()),
        let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
        let location = http.value(forHTTPHeaderField: "Location"),
        let next = URL(string: location, relativeTo: url)?.absoluteURL
      else { return nil }
      url = next
      if let link = redditLink(url.absoluteString), !link.post.isEmpty { return link }
    }
    return nil
  }

  static func redditTitle(_ value: String) async -> String? {
    var link = redditLink(value)
    if link?.share == true { link = await resolveRedditShare(value) }
    guard let link, !link.post.isEmpty else { return nil }
    let post = "https://www.reddit.com/r/\(link.subreddit ?? "reddit")/comments/\(link.post)/"
    guard let title = await oembedTitle("https://www.reddit.com/oembed?url=", post, limit: 280).title else { return nil }
    return link.comment != nil ? "Comment to \(title)" : title
  }

  static func youtubeVideo(_ value: String) -> String? {
    guard let url = URL(string: value), let host = url.host?.lowercased() else { return nil }
    let parts = pathParts(url)
    var id: String?
    if host == "youtu.be" {
      id = parts.first
    } else if youtubeHost.matches(host) {
      if parts.first == "watch" {
        id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
      } else if let first = parts.first, youtubePath.matches(first), parts.count > 1 {
        id = parts[1]
      }
    }
    guard let id, youtubeID.matches(id) else { return nil }
    return id
  }

  static func youtubeTitle(_ id: String) async -> String? {
    let video = "https://www.youtube.com/watch?v=\(id)"
    let result = await oembedTitle("https://www.youtube.com/oembed?format=json&url=", video, limit: 300)
    if let title = result.title { return title }
    guard result.status == 401 || result.status == 403, let url = URL(string: video),
      let title = await pageTitle(url)
    else { return nil }
    return title.range(of: #"^-?\s*YouTube$"#, options: [.regularExpression, .caseInsensitive]) == nil ? title : nil
  }

  static func oembedTitle(_ endpoint: String, _ target: String, limit: Int) async -> (title: String?, status: Int) {
    let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
    guard let url = URL(string: endpoint + encoded),
      let (data, response) = try? await session.data(for: request(url, accept: "application/json")),
      let http = response as? HTTPURLResponse
    else { return (nil, 0) }
    guard (200..<300).contains(http.statusCode),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let title = json["title"] as? String
    else { return (nil, http.statusCode) }
    let clean = String(cleanPageText(title).prefix(limit))
    return (clean.isEmpty ? nil : clean, http.statusCode)
  }
}
