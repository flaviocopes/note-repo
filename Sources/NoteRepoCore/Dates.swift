import Foundation

public enum Day {
  static let english = Locale(identifier: "en_US")

  public static func key(_ date: Date = Date()) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  public static var today: String { key() }

  public static func date(_ key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard key.count == 10, parts.count == 3 else { return nil }
    let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
    guard let date = Calendar.current.date(from: components), Day.key(date) == key else { return nil }
    return date
  }

  public static func isKey(_ value: String) -> Bool { date(value) != nil }

  public static func ordinal(_ day: Int) -> String {
    let remainder = day % 100
    if (11...13).contains(remainder) { return "\(day)th" }
    switch day % 10 {
    case 1: return "\(day)st"
    case 2: return "\(day)nd"
    case 3: return "\(day)rd"
    default: return "\(day)th"
    }
  }

  static func format(_ date: Date, _ template: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = english
    formatter.dateFormat = template
    return formatter.string(from: date)
  }

  public static func title(_ key: String) -> String {
    guard let date = date(key) else { return key }
    let day = Calendar.current.component(.day, from: date)
    return "\(format(date, "EEE")), \(format(date, "MMMM")) \(ordinal(day)), \(format(date, "yyyy"))"
  }

  public static func shortTitle(_ key: String) -> String {
    guard let date = date(key) else { return key }
    return format(date, "EEE, MMM d, yyyy")
  }

  public static func adding(_ days: Int, to key: String) -> String {
    guard let date = date(key), let moved = Calendar.current.date(byAdding: .day, value: days, to: date) else {
      return key
    }
    return Day.key(moved)
  }
}
