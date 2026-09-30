import AppKit
import NoteRepoCore
import SwiftUI

extension Notification.Name {
  static let tweetLoaded = Notification.Name("NoteRepoTweetLoaded")
}

struct TweetData {
  var name: String
  var handle: String
  var verified: Bool
  var avatar: NSImage?
  var text: String
  var photo: NSImage?
  var photoAspect: CGFloat
  var date: String
  var likes: Int
  var replies: Int
}

@MainActor
enum TweetCards {
  enum State {
    case loading
    case loaded(TweetData)
    case failed
  }

  static var states: [String: State] = [:]
  static var images: [String: NSImage] = [:]

  static func state(_ tweet: Tweet) -> State {
    if let state = states[tweet.id] { return state }
    states[tweet.id] = .loading
    Task {
      states[tweet.id] = await fetch(tweet)
      images = images.filter { !$0.key.hasPrefix("\(tweet.id):") }
      NotificationCenter.default.post(name: .tweetLoaded, object: tweet.id)
    }
    return .loading
  }

  static func image(for tweet: Tweet, width: CGFloat, dark: Bool) -> NSImage? {
    let state = state(tweet)
    let key = "\(tweet.id):\(Int(width)):\(dark)"
    if let image = images[key] { return image }
    let renderer = ImageRenderer(
      content: TweetCardView(tweet: tweet, state: state, dark: dark)
        .frame(width: width)
        .environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    var image: NSImage?
    NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
      image = renderer.nsImage
    }
    images[key] = image
    return image
  }

  static func download(_ value: String?) async -> NSImage? {
    guard let value, let url = URL(string: value),
      let (data, response) = try? await URLSession.shared.data(from: url),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return NSImage(data: data)
  }

  static func token(_ id: String) -> String {
    let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    let value = (Double(id) ?? 0) / 1e15 * Double.pi
    var integer = Int(value)
    var fraction = value - Double(integer)
    var text = ""
    repeat {
      text = String(digits[integer % 36]) + text
      integer /= 36
    } while integer > 0
    for _ in 0..<11 where fraction > 0 {
      fraction *= 36
      let digit = Int(fraction)
      text.append(digits[digit])
      fraction -= Double(digit)
    }
    let token = text.replacingOccurrences(of: "0", with: "")
    return token.isEmpty ? "a" : token
  }

  static func fetch(_ tweet: Tweet) async -> State {
    guard
      let url = URL(
        string: "https://cdn.syndication.twimg.com/tweet-result?id=\(tweet.id)&lang=en&token=\(token(tweet.id))"),
      let (data, response) = try? await URLSession.shared.data(from: url),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      json["__typename"] as? String == "Tweet",
      let user = json["user"] as? [String: Any]
    else { return .failed }

    var text = json["text"] as? String ?? ""
    if let range = json["display_text_range"] as? [Int], range.count == 2 {
      let scalars = Array(text.unicodeScalars)
      let lower = max(0, min(range[0], scalars.count))
      let upper = max(lower, min(range[1], scalars.count))
      text = String(String.UnicodeScalarView(scalars[lower..<upper]))
    }
    let urls = (json["entities"] as? [String: Any])?["urls"] as? [[String: Any]] ?? []
    for link in urls {
      if let short = link["url"] as? String, let display = link["display_url"] as? String {
        text = text.replacingOccurrences(of: short, with: display)
      }
    }
    text = text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")

    let media = (json["mediaDetails"] as? [[String: Any]])?.first
    let info = media?["original_info"] as? [String: Any]
    let aspect = CGFloat((info?["width"] as? Double) ?? 16) / CGFloat(max(1, (info?["height"] as? Double) ?? 9))
    let photoURL = (media?["media_url_https"] as? String).map { "\($0)?name=small" }
    let avatarURL = (user["profile_image_url_https"] as? String)?.replacingOccurrences(of: "_normal.", with: "_200x200.")

    async let avatar = download(avatarURL)
    async let photo = download(photoURL)

    var date = ""
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let created = (json["created_at"] as? String).flatMap(parser.date(from:)) {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US")
      formatter.dateFormat = "h:mm a · MMM d, yyyy"
      date = formatter.string(from: created)
    }

    return .loaded(
      TweetData(
        name: user["name"] as? String ?? tweet.user,
        handle: user["screen_name"] as? String ?? tweet.user,
        verified: (user["is_blue_verified"] as? Bool ?? false) || (user["verified"] as? Bool ?? false),
        avatar: await avatar,
        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
        photo: await photo,
        photoAspect: aspect,
        date: date,
        likes: json["favorite_count"] as? Int ?? 0,
        replies: json["conversation_count"] as? Int ?? 0))
  }
}

struct XLogo: Shape {
  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / 24
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
    var path = Path()
    let outer: [(CGFloat, CGFloat)] = [
      (18.244, 2.25), (21.552, 2.25), (14.325, 10.51), (22.827, 21.75), (16.17, 21.75), (10.956, 14.933),
      (4.99, 21.75), (1.68, 21.75), (9.41, 12.915), (1.254, 2.25), (8.08, 2.25), (12.793, 8.481),
    ]
    let inner: [(CGFloat, CGFloat)] = [(17.083, 19.77), (18.916, 19.77), (7.084, 4.126), (5.117, 4.126)]
    for shape in [outer, inner] {
      path.move(to: point(shape[0].0, shape[0].1))
      shape.dropFirst().forEach { path.addLine(to: point($0.0, $0.1)) }
      path.closeSubpath()
    }
    return path
  }
}

struct TweetCardView: View {
  let tweet: Tweet
  let state: TweetCards.State
  let dark: Bool

  private func rgb(_ hex: Int) -> Color { Color(Theme.rgb(hex)) }
  private var background: Color { dark ? rgb(0x000000) : rgb(0xffffff) }
  private var primary: Color { dark ? rgb(0xe7e9ea) : rgb(0x0f1419) }
  private var secondary: Color { dark ? rgb(0x71767b) : rgb(0x536471) }
  private var border: Color { dark ? rgb(0x2f3336) : rgb(0xcfd9de) }
  private var link: Color { dark ? rgb(0x1d9bf0) : rgb(0x006fd6) }

  var body: some View {
    switch state {
    case .loaded(let data): card(data)
    case .loading: fallback("Loading post preview…")
    case .failed: fallback("Preview unavailable · Open on X")
    }
  }

  private func fallback(_ status: String) -> some View {
    HStack(spacing: 13) {
      Text("X")
        .font(.system(size: 17, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 36, height: 36)
        .background(Circle().fill(rgb(0x050505)))
      VStack(alignment: .leading, spacing: 3) {
        Text("@\(tweet.user)").font(Font(Theme.mono(12, .bold))).foregroundStyle(Color(Theme.text)).lineLimit(1)
        Text(status).font(Font(Theme.mono(10))).foregroundStyle(Color(Theme.muted))
      }
      Spacer(minLength: 0)
    }
    .padding(17)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 13).fill(Color(Theme.card)))
    .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color(Theme.divider), lineWidth: 1))
  }

  private func compact(_ value: Int) -> String {
    func short(_ number: Double, _ suffix: String) -> String {
      let text = String(format: "%.1f", (number * 10).rounded(.down) / 10)
      return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
    }
    if value >= 1_000_000 { return short(Double(value) / 1_000_000, "M") }
    if value >= 1_000 { return short(Double(value) / 1_000, "K") }
    return "\(value)"
  }

  private func card(_ data: TweetData) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        Group {
          if let avatar = data.avatar {
            Image(nsImage: avatar).resizable().aspectRatio(contentMode: .fill)
          } else {
            Circle().fill(border)
          }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 3) {
            Text(data.name).font(.system(size: 15, weight: .bold)).foregroundStyle(primary).lineLimit(1)
            if data.verified {
              Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(rgb(0x1d9bf0))
            }
          }
          HStack(spacing: 4) {
            Text("@\(data.handle)").foregroundStyle(secondary)
            Text("·").foregroundStyle(secondary)
            Text("Follow").fontWeight(.bold).foregroundStyle(link)
          }
          .font(.system(size: 15))
          .lineLimit(1)
        }
        .padding(.top, 3)
        Spacer(minLength: 8)
        XLogo().fill(primary, style: FillStyle(eoFill: true)).frame(width: 25, height: 25)
      }

      if !data.text.isEmpty {
        Text(data.text)
          .font(.system(size: 20))
          .lineSpacing(4)
          .foregroundStyle(primary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 12)
      }

      if let photo = data.photo {
        Color.clear
          .aspectRatio(max(1, data.photoAspect), contentMode: .fit)
          .overlay(Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill))
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
          .padding(.top, 12)
      }

      HStack {
        Text(data.date).foregroundStyle(secondary)
        Spacer()
        Image(systemName: "info.circle").foregroundStyle(secondary)
      }
      .font(.system(size: 15))
      .padding(.top, 8)

      Rectangle().fill(border).frame(height: 1).padding(.top, 12)

      HStack(spacing: 20) {
        Label {
          Text(compact(data.likes))
        } icon: {
          Image(systemName: "heart.fill").foregroundStyle(rgb(0xf91880))
        }
        Label {
          Text("Reply")
        } icon: {
          Image(systemName: "bubble.left.fill").foregroundStyle(rgb(0x1d9bf0))
        }
        Label("Copy link to post", systemImage: "link")
      }
      .font(.system(size: 15, weight: .bold))
      .foregroundStyle(secondary)
      .padding(.top, 10)

      Text(data.replies > 0 ? "Read \(compact(data.replies)) replies" : "Read more on X")
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(link)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .padding(.top, 10)
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(background))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border, lineWidth: 1))
  }
}
