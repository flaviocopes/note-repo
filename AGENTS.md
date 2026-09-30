# NoteRepo workflow

- After every code or configuration change, rebuild the packaged macOS app.
- Quit the running NoteRepo app and launch the new build before reporting completion.
- Verify that the restarted app is running the new code.
- Build with `npm run package:mac`. For live checks, launch `release/mac-arm64/NoteRepo.app` with `--args --remote-debugging-port=9333` and run the `test/electron-*-check.cjs` scripts.
- Keep the NoteRepo window in front while checks run (`osascript -e 'tell application "NoteRepo" to activate'`). Hidden windows pause timers, `requestAnimationFrame`, and IntersectionObserver, so checks stall and can leave test content in today's note.
- The live checks write to the real notes database. For screenshots, demos, or risky experiments, launch with `--user-data-dir=<temp folder>` so the user's notes are never shown or changed.
- A fresh data folder still imports the legacy `~/Library/Application Support/noterepo/notes.json` (see `legacyPaths` in `electron/main.cjs`), so clear any imported days before recording a demo.
- For note data tasks (seeding demo days, backups, restores, reading a day), use the `noterepo` CLI instead of ad-hoc scripts: `node bin/noterepo.cjs help`, or the packaged `release/mac-arm64/NoteRepo.app/Contents/Resources/bin/noterepo`. It works while the app runs, and the app shows the changes live. `reset --yes` and `restore <backup> --yes` always back up first.
- `test/electron-cli-check.cjs` resets its notebook, so only run it against an app launched with a temporary `--user-data-dir`, and pass that folder as the second argument.
- `electron/outline.cjs` is the shared model of a day's text (parsing, renumbering, merging), used by the server, the store and the CLI. Link titles, including Reddit and YouTube, live in `electron/links.cjs`.
- Keep the UI minimalist and left-aligned. The light theme uses a neutral near-white, not a warm cream tint.
- `native/` is the experimental SwiftUI and AppKit version. It reads and writes the same `notes.sqlite3`, and `NoteRepoCore` mirrors `electron/outline.cjs`, `store.cjs` and `links.cjs`, so port changes in both directions. Build it with `native/build.sh`, run `swift test` in `native/`, and run the editor checks with `open -W --stdout <log> "native/build/NoteRepo Native.app" --args --user-data-dir <temp folder> --self-test`. `--round-trip` checks that every day saves back unchanged, and `--automation` plus `native/scripts/send.swift` takes window snapshots and runs commands like `jump DATE` or `dark`.
