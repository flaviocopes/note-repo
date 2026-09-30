import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard let kind = arguments.first, let value = arguments.dropFirst().first else {
  print("Usage: send snapshot PATH | send command 'jump 2026-09-28'")
  exit(2)
}
DistributedNotificationCenter.default().postNotificationName(
  Notification.Name("com.flaviocopes.noterepo.native.\(kind)"), object: value, userInfo: nil, deliverImmediately: true)
