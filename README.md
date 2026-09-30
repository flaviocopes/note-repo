<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.png" />
  <img src="docs/banner-light.png" alt="NoteRepo, a quiet, local-first daily notes app for macOS" />
</picture>

NoteRepo opens on today, which fills the whole window. Scroll up to see earlier days. Only the days where you wrote something show up, and there are no future days.

There are no accounts, AI tools, or calendar integrations. Your notes live in a SQLite file on your Mac.

Read the announcement on my blog: [I built NoteRepo, a quiet daily notes app for macOS](https://flaviocopes.com/noterepo/).

[![Watch the 30-second NoteRepo demo](docs/showreel-poster.jpg)](https://github.com/flaviocopes/noterepo/raw/main/docs/showreel.mp4)

## Download

Get `NoteRepo-1.1.0-arm64.zip` from the [latest release](https://github.com/flaviocopes/noterepo/releases/latest), unzip it, and drag NoteRepo to your Applications folder. The build runs on Apple silicon Macs. On an Intel Mac, [build it from source](#run-it-from-source).

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
- YouTube links show the video title, including Shorts, `youtu.be` and embed links
- Pasted text is cleaned of stray blank lines, trailing spaces, and invisible characters
- Rich previews for X and Twitter links pasted on their own line
- Images added by dragging a file into a day or pasting from the clipboard
- Image items you can select and delete, drag within a day, or move to another day
- Light and dark appearance following the macOS setting
- A [`noterepo` command-line tool](#use-it-from-the-command-line) that coding agents use to read and write your notes

![NoteRepo showing today's note with titled links and an X post preview](docs/screenshot.png)

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘D` | Go back to today and start writing |
| `⌘F` / `⌘K` | Search your notes |
| `⌥↑` / `⌥↓` | Move to the previous or next day |
| `Tab` / `Shift+Tab` | Indent or outdent a list item |

## Privacy

NoteRepo goes online in only two cases, and neither one sends your notes anywhere:

- When you paste a link, it downloads that page to read its title. For a Reddit or YouTube link, it asks that site's embed service for the title instead.
- When a note contains an X post, it loads the preview from `platform.twitter.com`.

## Use it from the command line

NoteRepo comes with `noterepo`, a command-line tool. I built it for coding agents, but you can use it too. It reads your days, adds items, links and images, moves things around, and backs up the notebook. Every command prints JSON.

The tool writes to the same SQLite file as the app. The app notices within a second and updates the open window, so you see the changes as they happen. If you're typing in the same day at that moment, your edits and the tool's are merged instead of one overwriting the other.

### Install it

The tool ships inside the app. Link it into a folder on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -s /Applications/NoteRepo.app/Contents/Resources/bin/noterepo ~/.local/bin/noterepo
```

It runs on the Node.js runtime inside the app, so you don't need Node installed. From a source checkout, run `npm link` instead.

### Read a day

`show` prints today's items:

```sh
noterepo show
```

```json
{
  "date": "2026-09-30",
  "title": "Wed, September 30th, 2026",
  "updatedAt": "2026-09-30T06:09:39.953Z",
  "items": [
    { "n": 1, "level": 0, "list": "bullet", "kind": "text", "text": "Call the bank" },
    { "n": 2, "level": 1, "list": "numbered", "number": 1, "kind": "text", "text": "Write the post" },
    {
      "n": 3,
      "level": 0,
      "list": "bullet",
      "kind": "link",
      "text": "[Write-Ahead Logging](https://sqlite.org/wal.html) (sqlite.org)",
      "links": [{ "title": "Write-Ahead Logging", "url": "https://sqlite.org/wal.html" }]
    }
  ],
  "content": "- Call the bank\n  1. Write the post\n- [Write-Ahead Logging](https://sqlite.org/wal.html) (sqlite.org)"
}
```

Each item has a number `n` and a `level`, where 0 is the top level and 1 is nested under the item before it. `kind` is `text`, `link`, `image`, or `post` for an X post. `content` is the day as NoteRepo stores it.

For another day, pass a date as `YYYY-MM-DD`, `today` or `yesterday`:

```sh
noterepo show yesterday
noterepo show 2026-09-28
```

`days` lists the days with notes, newest first, with a preview of each. `search` finds every item containing some text, grouped by day:

```sh
noterepo days --limit 5
noterepo days --from 2026-09-01 --to 2026-09-30
noterepo search bank
```

`noterepo info` shows the data folder, whether the app is running, and how many days and images you have.

### Add items

`add` puts an item at the end of today:

```sh
noterepo add "Call the bank"
```

Use `--date` for another day. `--after` and `--before` take an item number to place it. `--level 1` nests it under the item before it, and `--numbered` makes it a numbered item:

```sh
noterepo add "Pick up the parcel" --date yesterday
noterepo add "Write the post" --after 1 --level 1 --numbered
```

A URL on its own gets its page title, the same as pasting it in the app:

```sh
noterepo add https://sqlite.org/wal.html
```

It's saved as `[Write-Ahead Logging](https://sqlite.org/wal.html) (sqlite.org)`. Reddit links get the post title, and links to a comment read "Comment to" followed by the post title. YouTube links get the video title. X posts stay as URLs, so the app shows the preview. Add `--raw` to keep any URL as it is.

To check the title without writing anything, use `title`:

```sh
noterepo title https://sqlite.org/wal.html
```

`image` adds a PNG, JPEG, GIF, WebP or SVG file:

```sh
noterepo image ~/Desktop/receipt.png --date yesterday
```

### Change items

`edit`, `move` and `remove` use the item numbers from `show`. Every command that writes prints the updated day, so you always have the new numbers.

```sh
noterepo edit 1 "Call the bank about the card"
noterepo edit 3 --level 0
noterepo move 2 --before 1
noterepo move 4 --to yesterday
noterepo remove 3 4
```

`edit` changes the text, the level, or the list type with `--numbered` and `--bullet`. `move` works inside a day, or across days with `--to`. When you move or remove an item, its nested items go with it.

### Write whole days

`write` replaces a day with list lines from `--content` or stdin. Nest items with two spaces per level:

```sh
noterepo write yesterday <<'EOF'
- Shipped NoteRepo 1.1
  - Wrote the release notes
- https://sqlite.org/wal.html
EOF
```

Add `--append` to add the lines at the end of the day instead. To fill several days at once, pass a JSON object with `--json`:

```sh
noterepo write --json --content '{
  "2026-09-28": "- Plan for the week\n  1. Finish the post\n  2. Record the demo",
  "2026-09-25": ["- Newsletter sent", "- https://sqlite.org/wal.html"]
}'
```

`clear` deletes everything written on a day:

```sh
noterepo clear 2026-09-28
```

NoteRepo has no future days, so the commands that write only accept today and earlier days.

### Open the app on a day

`open` brings NoteRepo to the front and scrolls to a day. It starts the app if it isn't running:

```sh
noterepo open yesterday
```

### Back up and restore

`backup` saves a copy of every note and image in `~/Library/Application Support/NoteRepo/backups`:

```sh
noterepo backup
```

Before recording a demo, you can start from an empty notebook:

```sh
noterepo reset --yes
```

`reset` makes a backup first and prints where it saved it. Fill the days you want to show, record, then put your notes back:

```sh
noterepo restore ~/Library/Application\ Support/NoteRepo/backups/2026-09-29-213734-before-reset --yes
```

`restore` backs up the demo notes too, so nothing gets lost. Both commands work while the app is open.

### Errors and other data folders

When a command fails, it prints `{"error": "..."}` to stderr and exits with 1. A wrong command or option exits with 2.

`--data-dir` points the tool at another data folder, the same one you pass to the app with `--user-data-dir`. Use it to try things without touching your real notes:

```sh
noterepo show --data-dir /tmp/noterepo-demo
```

Run `noterepo help` for every command and option.

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
