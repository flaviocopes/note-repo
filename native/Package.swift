// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NoteRepo",
  platforms: [.macOS(.v15)],
  targets: [
    .target(name: "NoteRepoCore"),
    .executableTarget(name: "NoteRepo", dependencies: ["NoteRepoCore"]),
    .testTarget(name: "NoteRepoCoreTests", dependencies: ["NoteRepoCore"]),
  ],
  swiftLanguageModes: [.v5]
)
