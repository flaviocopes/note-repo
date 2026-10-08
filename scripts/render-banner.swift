#!/usr/bin/env swift
import AppKit

let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let size = CGSize(width: 1280, height: 560)
for (appearance, background, foreground) in [("light", NSColor(calibratedWhite: 0.98, alpha: 1), NSColor(calibratedWhite: 0.14, alpha: 1)), ("dark", NSColor(calibratedWhite: 0.09, alpha: 1), NSColor.white)] {
  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2560, pixelsHigh: 1120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  bitmap.size = size
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  background.setFill()
  NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 32, yRadius: 32).fill()
  NSImage(contentsOf: root.appending(path: "resources/AppIcon.png"))!.draw(in: CGRect(x: 78, y: 278, width: 150, height: 150))
  NSAttributedString(string: "Note Repo", attributes: [.font: NSFont.systemFont(ofSize: 68, weight: .bold), .foregroundColor: foreground]).draw(at: CGPoint(x: 78, y: 180))
  NSAttributedString(string: "A quiet daily notes app for macOS.", attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: foreground.withAlphaComponent(0.58)]).draw(at: CGPoint(x: 80, y: 135))
  let source = appearance == "dark" ? "docs/screenshot-dark.png" : "docs/screenshot.png"
  let screenshot = NSImage(contentsOf: root.appending(path: source))!
  screenshot.draw(in: CGRect(x: 658, y: -26, width: 880, height: 560))
  NSGraphicsContext.restoreGraphicsState()
  let output = root.appending(path: "docs/banner-\(appearance).png")
  try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
  print(output.path)
}
