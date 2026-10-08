<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.png" />
  <img src="docs/banner-light.png" alt="Note Repo, a quiet, local-first daily notes app for macOS" />
</picture>

Note Repo opens on today, which fills the whole window. Scroll up to see earlier days. Only the days where you wrote something show up, and there are no future days.

There are no accounts, AI tools, or calendar integrations. Your notes live in a SQLite file on your Mac.

Read the announcement on my blog: [I built Note Repo, a quiet daily notes app for macOS](https://flaviocopes.com/note-repo/).

[![Watch the 30-second Note Repo demo](docs/showreel-poster.jpg)](https://flaviocopes.com/note-repo/)

Note Repo is a native Mac app written in Swift. The [changelog](CHANGELOG.md) lists what changed in each release.

## Download

Get `Note-Repo-2.5.0.zip` from the [latest release](https://github.com/flaviocopes/note-repo/releases/latest), unzip it, and drag Note Repo to your Applications folder. It runs on Apple silicon and Intel Macs with macOS 14 or later.

Coming from 1.x? Replace the old app with the new one. Your notes stay where they are.

### Opening it the first time

Note Repo is signed with my Apple Developer ID and notarized by Apple. The first time you open it, macOS asks if you're sure you want to open an app downloaded from the internet. Click **Open**.

On a work laptop you might not be able to install apps in `/Applications`. You can keep Note Repo in the `Applications` folder inside your home folder instead.

### Updates

Once a day, Note Repo asks GitHub whether there's a newer version. When there is, it shows what's new, and **Install and Relaunch** puts it in place of the old one. **Note Repo → Check for Updates…** checks right away.

To turn off the daily check, run this in Terminal:

```sh
defaults write com.flaviocopes.noterepo AppUpdaterAutomaticChecks -bool false
```

## Features

- Today is always ready to write in, starting with a bullet
- Click a bullet to star an item. View starred, below Today, shows only starred items across your days. Click a star there to remove it, or click Today to return to the full editor.
- Continuous scrolling back through the days that have notes
- Bulleted and numbered lists started with `-` or `1.`
- Nested list items with `Tab` and `Shift+Tab`
- Several lines in one item with `⌥Return`
- Automatic saving
- Fast text search
- Pasted URLs become links showing the page title and domain, and a link pasted on its own starts a new bullet
- Reddit links show the post title, and links to a comment read "Comment to" followed by the post title
- YouTube links show the video title, including Shorts, `youtu.be` and embed links
- Pasted text is cleaned of stray blank lines, trailing spaces, and invisible characters
- X and Twitter links show the first line of the post
- Images added by dragging a file into a day or pasting from the clipboard
- Image items you can select and delete, or cut and paste into another day
- Light and dark appearance following the macOS setting
- A [`noterepo` command-line tool](#use-it-from-the-command-line) that coding agents use to read and write your notes

![Note Repo showing today's note with titled links](docs/screenshot.png)

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘D` | Go back to today and start writing |
| `⌘F` / `⌘K` | Search your notes |
| `⌥↑` / `⌥↓` | Move to the previous or next day |
| `Tab` / `Shift+Tab` | Indent or outdent a list item |
| `⌥Return` | Start a new line in the same item |

## Privacy

Note Repo goes online in only two cases. Your notes stay on this Mac:

- When you paste a link, it downloads that page to read its title. For a Reddit or YouTube link, it asks that site's embed service for the title instead. For an X post, it asks X's public embed service for the text and keeps the first line.
- Once a day, it asks GitHub for the latest Note Repo release, to check for an update. The request carries the app's name and version.

## Use it from the command line

Note Repo comes with `noterepo`, a command-line tool. I built it for coding agents, but you can use it too. It reads your days, adds items, links and images, moves things around, and backs up the notebook. Every command prints JSON.

The tool writes to the same SQLite file as the app. The app notices within a second and updates the open window, so you see the changes as they happen. If you're typing in the same day at that moment, your edits and the tool's are merged instead of one overwriting the other.

### Install it

The tool ships inside the app. Link it into a folder on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -s "/Applications/Note Repo.app/Contents/Resources/bin/noterepo" ~/.local/bin/noterepo
```

It's a native program, so you don't need anything else installed. From a source checkout, build the app with `scripts/build.sh` and link `build/Note Repo.app/Contents/Resources/bin/noterepo` instead.

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

Each item has a number `n` and a `level`, where 0 is the top level and 1 is nested under the item before it. `kind` is `text`, `link` or `image`. A starred item also has `"starred": true`. The day stores that star as `★` at the start of the line. `content` is the day as Note Repo stores it.

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

`<br>` is a line break inside an item, the same as `⌥Return` in the app:

```sh
noterepo add "Groceries<br>milk, eggs"
```

A URL on its own gets its page title, the same as pasting it in the app:

```sh
noterepo add https://sqlite.org/wal.html
```

It's saved as `[Write-Ahead Logging](https://sqlite.org/wal.html) (sqlite.org)`. Reddit links get the post title, and links to a comment read "Comment to" followed by the post title. YouTube links get the video title. An X post gets the first line of its text. Add `--raw` to keep any URL as it is.

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
- Shipped Note Repo 1.1
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

Note Repo has no future days, so the commands that write only accept today and earlier days.

### Open the app on a day

`open` brings Note Repo to the front and scrolls to a day. It starts the app if it isn't running:

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

Agents can ask what the CLI can do without touching your notes: `noterepo capabilities` prints a short summary and task list, and `noterepo capabilities --json` prints the same manifest that tools like `clitools` collect.

## Build it from source

You need macOS 14 or later and Xcode 16 or later, or its command line tools.

```sh
scripts/build.sh
open "build/Note Repo.app"
```

The script builds `build/Note Repo.app` for Apple silicon and Intel, with the `noterepo` tool inside. It signs the app with my Developer ID when that certificate is in the keychain, and ad hoc everywhere else, so your copy is signed ad hoc. Drag it to your Applications folder.

A copy you build yourself opens without a warning on your Mac. If you send it to another Mac, macOS says it "could not verify Note Repo is free of malware". Click **Done**, then go to **System Settings → Privacy & Security** and click **Open Anyway**.

## Where your notes live

Notes and images are stored in one SQLite database:

```text
~/Library/Application Support/NoteRepo/notes.sqlite3
```

Every copy of Note Repo on your Mac uses this file, so back it up like any other document, or run `noterepo backup`.

Note Repo accepts PNG, JPEG, GIF, WebP, and safe SVG images up to 15 MB each. Identical images are stored only once.

## Development

Run the unit tests. They cover the notes model, link titles and every `noterepo` command:

```sh
swift test
```

The app has three switches for checking changes. Each one needs `--user-data-dir` with a temporary folder, so your real notes stay out of it:

- `--self-test` types, pastes and undoes in a real editor, then checks what gets saved and merged. It prints one line per check and quits.
- `--round-trip` opens every day and checks that saving it gives back the same text, without writing anything. Run it on a copy made with `noterepo backup`.
- `--automation` lets `scripts/send.swift` save a snapshot of the window, or run commands like `jump 2026-09-28` and `dark`.

```sh
open -W --stdout /tmp/noterepo-check.log "build/Note Repo.app" --args --user-data-dir /tmp/noterepo-check --self-test
cat /tmp/noterepo-check.log
```

The app icon lives in `resources/AppIcon.svg`, and the build uses `resources/AppIcon.png`.

## How it works

SwiftUI draws the window, the sidebar and search. Each day is an AppKit text view, because SwiftUI's own rich text editor needs macOS 26. The editor draws the bullets and numbers in the margin, shows links by their titles, and puts images inside the text as attachments. When you save, it turns the day back into Markdown list lines. A line break inside an item is saved as `<br>`, so every item stays on one line.

Notes and images go into SQLite through the `sqlite3` library that comes with macOS. `NoteRepoCore` holds the parts the app and the `noterepo` tool share: the notes model, the database, and the code that fetches link titles.

The app checks SQLite's `data_version` every half second. When another process changed something, like the `noterepo` tool, it reloads the days that changed. Every save carries the text the editor started from. When that text no longer matches the database, Note Repo merges the two versions line by line instead of overwriting the other change.

## License

[MIT](LICENSE)
