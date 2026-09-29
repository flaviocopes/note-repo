<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.png" />
  <img src="docs/banner-light.png" alt="NoteRepo, a quiet, local-first daily notes app for macOS" />
</picture>

NoteRepo opens on today, which fills the whole window. Scroll up to see earlier days. Only the days where you wrote something show up, and there are no future days.

There are no accounts, AI tools, or calendar integrations. Your notes live in a SQLite file on your Mac.

Read the announcement on my blog: [I built NoteRepo, a quiet daily notes app for macOS](https://flaviocopes.com/noterepo/).

[![Watch the 30-second NoteRepo demo](docs/showreel-poster.jpg)](https://github.com/flaviocopes/noterepo/raw/main/docs/showreel.mp4)

## Download

Get `NoteRepo-1.0.0-arm64.zip` from the [latest release](https://github.com/flaviocopes/noterepo/releases/latest), unzip it, and drag NoteRepo to your Applications folder. The build runs on Apple silicon Macs. On an Intel Mac, [build it from source](#run-it-from-source).

### Opening it the first time

NoteRepo isn't signed with an Apple Developer ID or notarized by Apple, and I don't plan to change that. So the first time you open it, macOS says it "could not verify NoteRepo is free of malware". Click **Done**, then allow it in one of two ways.

In System Settings, open **Privacy & Security** and scroll down to the message about NoteRepo. Click **Open Anyway**, confirm, and open the app again. The button shows up for about an hour after you try to open the app.

In Terminal, remove the quarantine flag macOS adds to downloaded files, then open the app:

```sh
xattr -dr com.apple.quarantine /Applications/NoteRepo.app
```

The same command fixes a message saying NoteRepo is damaged. You don't need to turn off Gatekeeper for either option.

On a work laptop you might not be able to install apps in `/Applications`. You can keep NoteRepo in the `Applications` folder inside your home folder, and run the command on `~/Applications/NoteRepo.app`. If your company blocks apps that aren't notarized, ask your IT team.

## Features

- Today is always ready to write in, starting with a bullet
- Continuous scrolling back through the days that have notes
- Bulleted and numbered lists started with `-` or `1.`
- Nested list items with `Tab` and `Shift+Tab`
- Automatic saving
- Fast text search
- Pasted URLs become links showing the page title and domain, and a link pasted on its own starts a new bullet
- Reddit links show the post title, and links to a comment read "Comment to" followed by the post title
- Pasted text is cleaned of stray blank lines, trailing spaces, and invisible characters
- Rich previews for X and Twitter links pasted on their own line
- Images added by dragging a file into a day or pasting from the clipboard
- Image items you can select and delete, drag within a day, or move to another day
- A date picker that jumps to the closest day with notes
- Light and dark appearance following the macOS setting
- A `noterepo` command-line tool that coding agents use to read and write your notes

![NoteRepo showing today's note with titled links and an X post preview](docs/screenshot.png)

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘D` | Go back to today and start writing |
| `⌘K` | Search your notes |
| `⌥↑` / `⌥↓` | Move to the previous or next day |
| `Tab` / `Shift+Tab` | Indent or outdent a list item |

## Privacy

NoteRepo goes online in only two cases, and neither one sends your notes anywhere:

- When you paste a link, it downloads that page to read its title. For a Reddit link, it asks Reddit's embed service for the post title instead.
- When a note contains an X post, it loads the preview from `platform.twitter.com`.

## Use it from an agent

NoteRepo comes with `noterepo`, a command-line tool for coding agents. An agent can read your days, add items, links and images, move things around, and back up the notebook. Every command prints JSON.

The tool writes to the same SQLite file as the app. The app notices within a second and updates the open window, so you see the agent's edits as they happen. If you're typing in the same day at that moment, your edits and the agent's are merged instead of one overwriting the other.

### Install it

The tool ships inside the app. Link it into a folder on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -s /Applications/NoteRepo.app/Contents/Resources/bin/noterepo ~/.local/bin/noterepo
```

It runs on the Node.js runtime inside the app, so you don't need Node installed. From a source checkout, run `npm link` instead.

### Try it

```sh
noterepo show
noterepo add "Call the bank"
noterepo add "https://news.ycombinator.com/item?id=49854875"
noterepo add "Write the post" --after 1 --level 1 --numbered
noterepo days --limit 5
```

`show` lists every item of a day with a number, and `edit`, `remove` and `move` use those numbers. A link on its own gets its page title, like when you paste it. X posts stay as URLs, so the app shows the preview.

To fill several days at once, pass a JSON object:

```sh
noterepo write --json --content '{
  "2026-09-28": "- Plan for the week\n  1. Finish the post\n  2. Record the demo",
  "2026-09-25": ["- Newsletter sent", "- https://sqlite.org/wal.html"]
}'
```

### Prepare a demo

Before recording a demo, start from an empty notebook:

```sh
noterepo reset --yes
```

`reset` makes a backup first and prints where it saved it. Fill the days you want to show, record, then put your notes back:

```sh
noterepo restore ~/Library/Application\ Support/NoteRepo/backups/2026-09-29-213734-before-reset --yes
```

`restore` backs up the demo notes too, so nothing gets lost. Both commands work while the app is open.

Run `noterepo help` for everything else: `info`, `search`, `title`, `image`, `clear`, `open`, and `backup`. Add `--data-dir` to work on another data folder, the same one you pass to the app with `--user-data-dir`.

## Run it from source

You need macOS and [Node.js](https://nodejs.org) 22.13 or later.

Install the dependencies:

```sh
npm install
```

Build the interface and open the app:

```sh
npm run dev
```

## Build the macOS app

```sh
npm run package:mac
```

The app appears in `release/mac-arm64/NoteRepo.app` on Apple silicon Macs. Drag it to your Applications folder.

The build is ad-hoc signed and not notarized. A copy you build yourself opens without a warning. If you send it to another Mac, it can get the same warning as the download, so follow [Opening it the first time](#opening-it-the-first-time).

## Where your notes live

Notes and images are stored in one SQLite database:

```text
~/Library/Application Support/NoteRepo/notes.sqlite3
```

The development and packaged apps share this file, so back it up like any other document.

NoteRepo accepts PNG, JPEG, GIF, WebP, and safe SVG images up to 15 MB each. Identical images are stored only once.

## Import from Reflect

If you're coming from [Reflect](https://reflect.app), export your notes as JSON and import the daily notes.

Quit NoteRepo first, then preview what would change:

```sh
node scripts/import-reflect.cjs \
  --source ~/Downloads/reflect-export.json \
  --database ~/Library/Application\ Support/NoteRepo/notes.sqlite3 \
  --dry-run
```

Run the same command without `--dry-run` to import. The script backs up your database next to it first, downloads your Reflect images into NoteRepo, and appends Reflect notes to days that already have notes. Running it twice doesn't duplicate anything.

## Development

Run the type check, the build, and the unit tests:

```sh
npm run check
```

The `test/electron-*-check.cjs` scripts drive the running app through the Chrome DevTools Protocol. Start the packaged app with remote debugging turned on:

```sh
open -a release/mac-arm64/NoteRepo.app --args --remote-debugging-port=9333
```

Copy the page's `webSocketDebuggerUrl` from `http://127.0.0.1:9333/json` and pass it to each check:

```sh
node test/electron-cdp-check.cjs ws://127.0.0.1:9333/devtools/page/<id>
node test/electron-feed-check.cjs ws://127.0.0.1:9333/devtools/page/<id>
node test/electron-import-check.cjs ws://127.0.0.1:9333/devtools/page/<id> 2026-09-05
```

The import check also needs a date whose note contains an image.

Be careful: these checks use your real notes database. They edit today's note and restore it afterwards, and they write to a few days in December 1999. Keep the NoteRepo window visible while they run, because macOS pauses hidden windows.

The CLI check drives the app with the packaged `noterepo` tool and resets its notebook, so it refuses to run on your real notes. Launch the app on an empty folder and pass that folder to the check:

```sh
open -a release/mac-arm64/NoteRepo.app --args --remote-debugging-port=9333 --user-data-dir=/tmp/noterepo-check
node test/electron-cli-check.cjs ws://127.0.0.1:9333/devtools/page/<id> /tmp/noterepo-check
```

The app icon lives in `resources/AppIcon.svg`. After editing it, regenerate the PNGs used by the build:

```sh
npm run icon
```

The README banner is `docs/banner.html`, styled with the app's own stylesheet. Regenerate the light and dark PNGs with:

```sh
npm run banner
```

## How it works

Astro builds the interface. HTMX loads earlier days as you scroll up. Alpine.js tracks the active day, grows each editor, and saves your writing.

Electron runs a small server bound to `127.0.0.1`. It stores notes and images in SQLite through Node's built-in `node:sqlite` module, fetches the titles of pasted links, and opens web links in your default browser. The renderer is sandboxed and has no direct access to Node.js.

The `noterepo` tool opens the same database. The app checks SQLite's `data_version` every half second, and when another process changed something, it reloads the days that changed. Every save from the editor carries the text it started from. When that text no longer matches the database, the server merges the two versions line by line instead of overwriting the other change.

## License

[MIT](LICENSE)
