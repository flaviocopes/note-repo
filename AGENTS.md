# NoteRepo

A daily notes app for macOS, written in Swift, with a `noterepo` CLI for agents. Both read and write `~/Library/Application Support/NoteRepo/notes.sqlite3`.

## Files

- `Sources/NoteRepoCore/`: shared by the app and the CLI.
  - `Outline.swift`: the model of a day's text. It parses list lines, renumbers them, and describes items for the CLI. It also merges an outside change into unsaved edits. `serialize` keeps untouched lines as they were saved, and `normalized` formats every line the way the editor saves them.
  - `Store.swift`: the SQLite database: notes, images, search, backups and restores.
  - `Links.swift`: inline links and images in a line, X post URLs, and page titles, with Reddit and YouTube handling.
  - `Dates.swift`, `Images.swift` (image type checks), and `Version.swift`, the one place the version lives.
- `Sources/NoteRepoApp/`: the app.
  - `NoteTextView.swift`: the editor, an `NSTextView`. It handles bullets, Tab nesting, paste and drop, and copy as Markdown.
  - `NoteFormat.swift`: turns Markdown into the editor's text and back. A line break inside an item (⌥Return) is a U+2028 line separator in the editor and `<br>` in the saved text, so every item stays on one line.
  - `Feed.swift`: the scrolling list of days, saving, and reloading days changed outside the app.
  - `Attachments.swift` and `TweetCard.swift`: images and X post cards.
  - `ContentView.swift`, `AppModel.swift`, `Theme.swift` and `main.swift`: the window, sidebar, search, colors and menus.
  - `SelfTest.swift` and `Automation.swift`: the `--self-test`, `--round-trip` and `--automation` switches.
  - `AppUpdater.swift`: checks the GitHub releases once a day and installs updates. It's an identical copy of the template in the `mac-app-updater` skill, so change the template and copy it over instead of editing it here.
- `Sources/NoteRepoCLI/`: every `noterepo` command, plus `JSON.swift`, which prints JSON exactly like `JSON.stringify(value, null, 2)`. The agent-ready manifest lives in `Manifest.swift`; add a changelog entry there on every version bump. `Sources/noterepo/main.swift` runs it.
- `Tests/`: unit tests for the model, link titles and every CLI command.
- `resources/`: `Info.plist` and the icon. `scripts/build.sh` builds the app, `scripts/notarize.sh` makes the notarized release zip, and `scripts/send.swift` talks to `--automation`.

## Build and run

```sh
swift test                                   # unit tests
scripts/build.sh                             # build/NoteRepo.app, universal, with the CLI inside, Developer ID signed when the certificate is in the keychain
open build/NoteRepo.app                      # run it on the real notes
build/NoteRepo.app/Contents/Resources/bin/noterepo help
scripts/notarize.sh                          # build, notarize, staple, and write dist/NoteRepo-<version>.zip
```

## Rules

- After every code or configuration change, run `swift test` and `scripts/build.sh`. Then quit the running NoteRepo (`osascript -e 'tell application id "com.flaviocopes.noterepo" to quit'`), open the new build, and check it's the new version before reporting completion.
- The user's notes never go into the repo, screenshots or demos. For screenshots, demos and experiments, launch with `--args --user-data-dir <temp folder>` and pair the CLI with `--data-dir` on the same folder.
- Check editor changes with the self-test, on a temporary folder:
  `open -W --stdout /tmp/noterepo-check.log build/NoteRepo.app --args --user-data-dir /tmp/noterepo-check --self-test`
  Launch it with `open`, so the app is active and ⌘Z reaches the Edit menu. Add a check to `SelfTest.swift` for any new editing behavior.
- Quit NoteRepo before any `open ... --args` launch. If it's already running, `open` only brings it forward and drops the arguments, so `open -W` hangs. Opening it right after it quits, or right after a self-test exits, can fail with error -600, so wait a second and retry.
- Agents can't send keystrokes through System Events here. Drive the editor from `SelfTest.swift`, or with `--automation` commands like `swift scripts/send.swift command today`.
- Before changing how days are read or saved, back up with `noterepo backup`, then run `--round-trip` on that copy. It must report 0 days that differ.
- For screenshots, launch with `--automation` and run `swift scripts/send.swift snapshot /tmp/shot.png`. The app captures its own window, so it needs no screen recording permission.
- For note data tasks like seeding demo days, backups, restores or reading a day, use the `noterepo` CLI. It works while the app runs, and the app shows the changes within a second. `reset --yes` and `restore <backup> --yes` always back up first.
- Agents depend on the CLI's commands, options and JSON output, so keep them stable and add tests for any change.
- Keep the UI minimalist and left-aligned. The light theme uses a neutral near-white, not a warm cream tint.
- Releases are signed with Flavio's Developer ID (team `DGFKNTAG99`) with the hardened runtime, and notarized by `scripts/notarize.sh`. It needs the certificate in the keychain and a notarytool keychain profile named `notary`, and it refuses an ad-hoc build. CI and forks have no certificate, so `scripts/build.sh` signs ad-hoc there. Every release gets a section in `CHANGELOG.md`, newest first.
- Pick the version with semver: a minor release (2.2.0) for a new feature or any change people notice, like the move to notarization, and a point release (2.2.1) only for bug fixes.
- The updater trusts the GitHub release. Every release needs its `vX.Y.Z` tag, the zip from `scripts/notarize.sh` attached, and a version in `Version.swift` that matches the tag, or the app refuses the update. It shows the release notes up to the first `## Install` heading, so put what's new first.
