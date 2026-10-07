import AppKit
import SwiftUI

enum Theme {
  static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }

  static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
      blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
  }

  static let background = dynamic(rgb(0xfafafa), rgb(0x14191b))
  static let raised = dynamic(rgb(0xf2f2f2), rgb(0x242b2d))
  static let field = dynamic(rgb(0x000000, 0.035), rgb(0xffffff, 0.04))
  static let popover = dynamic(rgb(0xffffff), rgb(0x1b2123))
  static let shadow = dynamic(rgb(0x000000, 0.12), rgb(0x000000, 0.35))
  static let divider = dynamic(rgb(0x000000, 0.07), rgb(0xffffff, 0.07))
  static let text = dynamic(rgb(0x141414, 0.9), rgb(0xffffff, 0.9))
  static let muted = dynamic(rgb(0x141414, 0.5), rgb(0xffffff, 0.45))
  static let faint = dynamic(rgb(0x141414, 0.3), rgb(0xffffff, 0.25))
  static let accent = dynamic(rgb(0x0b63d6), rgb(0x4ea1ff))
  static let star = dynamic(rgb(0xf0b000), rgb(0xffd24d))
  static let red = dynamic(rgb(0xd1274f), rgb(0xf84d75))
  static let linkUnderline = dynamic(rgb(0x0b63d6, 0.4), rgb(0x4ea1ff, 0.4))
  static let accentGlow = dynamic(rgb(0x0b63d6, 0.35), rgb(0x4ea1ff, 0.35))
  static let accentBorder = dynamic(rgb(0x0b63d6, 0.4), rgb(0x4ea1ff, 0.4))

  static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .monospacedSystemFont(ofSize: size, weight: weight)
  }
}

extension Color {
  init(_ color: NSColor) { self.init(nsColor: color) }
}
