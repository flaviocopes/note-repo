import AppKit
import NoteRepoCLI

let context = CLIContext(
  arguments: Array(CommandLine.arguments.dropFirst()),
  environment: ProcessInfo.processInfo.environment,
  currentDirectory: FileManager.default.currentDirectoryPath,
  readStdin: {
    isatty(STDIN_FILENO) == 1 ? "" : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  },
  runningApp: {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.flaviocopes.noterepo" }?.bundleURL?.path
  },
  open: { arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
  })

let output = await CLI.run(context)
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.code)
