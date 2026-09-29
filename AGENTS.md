# NoteRepo workflow

- After every code or configuration change, rebuild the packaged macOS app.
- Quit the running NoteRepo app and launch the new build before reporting completion.
- Verify that the restarted app is running the new code.
- Build with `npm run package:mac`. For live checks, launch `release/mac-arm64/NoteRepo.app` with `--args --remote-debugging-port=9333` and run the `test/electron-*-check.cjs` scripts.
- Keep the NoteRepo window in front while checks run (`osascript -e 'tell application "NoteRepo" to activate'`). Hidden windows pause timers, `requestAnimationFrame`, and IntersectionObserver, so checks stall and can leave test content in today's note.
- The live checks write to the real notes database. For screenshots, demos, or risky experiments, launch with `--user-data-dir=<temp folder>` so the user's notes are never shown or changed.
- A fresh data folder still imports the legacy `~/Library/Application Support/noterepo/notes.json` (see `legacyPaths` in `electron/main.cjs`), so clear any imported days before recording a demo.
- Keep the UI minimalist and left-aligned. The light theme uses a neutral near-white, not a warm cream tint.
