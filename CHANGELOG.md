# Changelog

Every Note Repo release, newest first. Downloads are on the [releases page](https://github.com/flaviocopes/note-repo/releases).

## 2.5.0 (October 8, 2026)

- Renamed the app to Note Repo.
- Updated its GitHub repository, app bundle and download names. Existing saved data and commands still work.

## 2.4.0 (October 7, 2026)

- **Star items.** Hover a bullet or number and click to star the item. Click the star again to remove it. Stars stay with their items when you save, reload, or edit them with the CLI.
- **View starred.** The button below Today shows starred items from every day in the main feed. Links still work, and clicking a star removes it from this view. Click Today to return to the full editor.
- Spelling and grammar checks are off in the editor.
- The CLI includes `"starred": true` for starred items in its JSON output.

## 2.3.0 (October 7, 2026)

- **X posts are links.** Paste a post from X and you get the first line of its text, the same way a blog link shows its title. `noterepo add` does the same. The preview card is gone. A post you saved before stays as its URL until you paste the link again.

## 2.2.0 (October 3, 2026)

- **Signed and notarized.** Note Repo is now signed with my Apple Developer ID and notarized by Apple. The first time you open it, macOS no longer says it "could not verify Note Repo is free of malware", so you don't need **Open Anyway** or Terminal. It asks the usual question about opening an app downloaded from the internet, and you click **Open**.
- Nothing else changed. Your notes, the `noterepo` CLI and the link to it stay the same.

## 2.1.0 (September 30, 2026)

- **Updates from inside the app.** Once a day, Note Repo asks GitHub for a newer version. When there is one, it shows what's new, and **Install and Relaunch** puts it in place of the old app. **Note Repo → Check for Updates…** checks right away. 2.1 is the last version you install by hand.
- **Several lines in one item.** `⌥Return` starts a new line inside the same item, instead of a new item. It's saved as `<br>`, so each item is still one line of Markdown, and the `noterepo` CLI reads and writes it the same way.
- **Search results stay in their panel.** A search with many matches used to spill its results over the sidebar and the window buttons. Now they scroll inside the panel.
- **The cursor on an empty item.** On an empty last item, the blinking cursor was shorter than the line and sat too high. Now it lines up with the bullet.

## 2.0.0 (September 30, 2026)

Note Repo is now a native Mac app written in Swift. It looks and works like 1.2, opens the same notes, and replaces the Electron version.

- **A native app.** SwiftUI draws the window, the sidebar and search, and each day is an AppKit text view. The download went from 122 MB to 1.5 MB. On the same notes, the app uses about 70 MB of memory instead of 190 MB, in one process instead of five.
- **Intel Macs.** The app is universal, so it runs on Intel Macs as well as Apple silicon. It needs macOS 14 or later.
- **A native `noterepo`.** The command-line tool is now a Swift program. Its commands, options and JSON output are the same as in 1.2, and it lives in the same place inside the app, so your links and your agents' scripts keep working. It doesn't need the Node.js runtime anymore.
- **X post previews drawn by the app.** Note Repo reads the post's author, text, photo and counts from X's public embed service and draws the card itself, in light and dark, instead of loading X's embed script.
- **Your notes come along.** 2.0 reads and writes the same `notes.sqlite3` file, so updating means replacing the app.
- **No more Reflect importer.** It was a script in the repository, not part of the app.

A few things are different:

- To move an image to another day, cut and paste it. Dragging images between days isn't tested in the native editor yet.
- Note Repo no longer imports the `notes.json` file used by its first development builds.

## 1.2.0 (September 30, 2026)

- **YouTube titles.** Paste a YouTube link and you get the video title. It works for Shorts, `youtu.be` links and embed links too, and `noterepo add` does the same. If a video was removed or made private, the link stays as a plain URL instead of reading "- YouTube".
- **⌘F searches.** ⌘F puts the cursor in the search field, the same as ⌘K.
- **No more date picker.** The sidebar has only Today and search. Search results, ⌘D and `noterepo://day/…` links still take you to any day.

## 1.1.0 (September 29, 2026)

- **A CLI for agents.** `noterepo` reads and writes the same notes as the app, and every command prints JSON. An agent can add items, links and images, edit, move and remove them, fill many days at once, search, and back up or restore the whole notebook.
- **Live updates.** Changes made with the CLI show up in the open window within a second. If you're typing in the same day at that moment, your text and the agent's are merged instead of one overwriting the other.
- **Reddit titles.** Reddit links show the post title. Links to a comment read "Comment to" followed by the post title.

## 1.0.0 (September 29, 2026)

The first public release.

- Opens on today, with the earlier days that have notes above it
- Bulleted, numbered, and nested lists
- Pasted links show the page title and domain
- Previews for X posts
- Images by drag and drop or paste
- Search with ⌘K, and ⌘D to jump back to today
- Light and dark appearance that follows macOS
- An importer for Reflect daily notes
