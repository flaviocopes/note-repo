import Foundation

public enum ImageData {
  public static let mimeTypes = ["image/gif", "image/jpeg", "image/png", "image/svg+xml", "image/webp"]

  static let svgStart = NSRegularExpression(#"^(?:<\?xml[^>]*>\s*)?<svg\b"#, .caseInsensitive)
  static let svgUnsafe = NSRegularExpression(
    #"<!doctype|<script|<foreignObject|<(?:iframe|object|embed)\b|\bon\w+\s*=|(?:href|xlink:href)\s*=\s*["']\s*(?:https?:|//|data:)|url\s*\(\s*["']?\s*(?:https?:|//|data:)"#,
    .caseInsensitive)

  public static func hasSignature(_ data: Data, _ mimeType: String) -> Bool {
    let bytes = [UInt8](data.prefix(12))
    switch mimeType {
    case "image/png": return bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    case "image/jpeg": return bytes.starts(with: [0xff, 0xd8, 0xff])
    case "image/gif":
      let signature = String(decoding: bytes.prefix(6), as: UTF8.self)
      return signature == "GIF87a" || signature == "GIF89a"
    case "image/webp":
      return bytes.count >= 12 && bytes[0..<4].elementsEqual(Array("RIFF".utf8))
        && bytes[8..<12].elementsEqual(Array("WEBP".utf8))
    case "image/svg+xml":
      let source = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      return svgStart.matches(source) && !svgUnsafe.matches(source)
    default: return false
    }
  }

  public static func mimeType(_ data: Data) -> String? {
    mimeTypes.first { hasSignature(data, $0) }
  }
}
