// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "NoteRepo",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "NoteRepoApp", targets: ["NoteRepoApp"]),
    .executable(name: "noterepo", targets: ["noterepo"]),
  ],
  targets: [
    .target(name: "NoteRepoCore"),
    .target(name: "NoteRepoCLI", dependencies: ["NoteRepoCore"]),
    .executableTarget(name: "NoteRepoApp", dependencies: ["NoteRepoCore"]),
    .executableTarget(name: "noterepo", dependencies: ["NoteRepoCLI"]),
    .testTarget(name: "NoteRepoCoreTests", dependencies: ["NoteRepoCore"]),
    .testTarget(name: "NoteRepoCLITests", dependencies: ["NoteRepoCLI", "NoteRepoCore"]),
  ],
  swiftLanguageModes: [.v5]
)
