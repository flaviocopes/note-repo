const assert = require('node:assert/strict')
const fs = require('node:fs/promises')
const http = require('node:http')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const { NoteStore, hasNoteContent, isDateKey } = require('../electron/store.cjs')
const {
  createAppServer,
  daySection,
  dayTitle,
  escapeHtml,
  extractPageTitle,
  feedAfter,
  feedBefore,
  feedInitial,
  hasImageSignature,
  renderNoteHtml,
  todayKey,
} = require('../electron/server.cjs')
const {
  detectImageMime,
  documentToContent,
  importNotes,
  upgradeImageReferences,
  validateReflectImageUrl,
} = require('../scripts/import-reflect.cjs')

const PIXEL_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
)

const setupStore = async (context) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'noterepo-'))
  const stores = []

  context.after(async () => {
    for (const store of stores) store.close()
    await fs.rm(directory, { recursive: true, force: true })
  })

  return {
    directory,
    open: async ({ legacyPaths = [] } = {}) => {
      const store = await new NoteStore(path.join(directory, 'notes.sqlite3'), {
        legacyPaths,
      }).load()
      stores.push(store)
      return store
    },
  }
}

test('validates real calendar dates', () => {
  assert.equal(isDateKey('2026-08-28'), true)
  assert.equal(isDateKey('2026-02-30'), false)
  assert.equal(isDateKey('not-a-date'), false)
})

test('recognizes meaningful note content', () => {
  assert.equal(hasNoteContent(' \n\t '), false)
  assert.equal(hasNoteContent('- '), false)
  assert.equal(hasNoteContent('1. '), false)
  assert.equal(hasNoteContent('- Buy milk'), true)
})

test('saves and reloads daily notes', async (context) => {
  const { directory, open } = await setupStore(context)
  const store = await open()

  await store.save('2026-08-28', 'Built NoteRepo today.\nhttps://example.com')
  store.close()

  const reloaded = await open()
  assert.equal(reloaded.get('2026-08-28').content, 'Built NoteRepo today.\nhttps://example.com')
  assert.equal(reloaded.has('2026-08-28'), true)
  for (const suffix of ['', '-shm', '-wal']) {
    const databasePath = path.join(directory, `notes.sqlite3${suffix}`)
    assert.equal((await fs.stat(databasePath)).mode & 0o777, 0o600)
  }
})

test('finds matching note text newest first', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()

  await store.save('2026-08-27', 'Read about local-first software')
  await store.save('2026-08-28', 'Built a local-first notes app')

  assert.deepEqual(
    store.search('LOCAL-FIRST').map((note) => note.date),
    ['2026-08-28', '2026-08-27'],
  )
})

test('lists only notes with content before and after a date', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()

  await store.save('2026-08-20', 'Earlier note')
  await store.save('2026-08-21', ' \n\t ')
  await store.save('2026-08-22', '- ')
  await store.save('2026-08-28', 'Anchor note')
  await store.save('2026-08-30', 'Later note')

  assert.deepEqual(
    store.contentNotesBefore('2026-08-28').map((note) => note.date),
    ['2026-08-20'],
  )
  assert.deepEqual(
    store.contentNotesAfter('2026-08-28').map((note) => note.date),
    ['2026-08-30'],
  )
})

test('stores image data in SQLite and deduplicates matching files', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()

  const first = store.saveImage({
    data: PIXEL_PNG,
    mimeType: 'image/png',
    fileName: 'screenshot.png',
    width: 1,
    height: 1,
  })
  const duplicate = store.saveImage({
    data: PIXEL_PNG,
    mimeType: 'image/png',
    fileName: 'duplicate.png',
  })
  const saved = store.getImage(first.id)

  assert.equal(first.id.length, 64)
  assert.equal(duplicate.id, first.id)
  assert.equal(saved.fileName, 'screenshot.png')
  assert.equal(saved.mimeType, 'image/png')
  assert.equal(saved.width, 1)
  assert.equal(saved.height, 1)
  assert.deepEqual(saved.data, PIXEL_PNG)
})

test('migrates legacy JSON once and keeps the newest note', async (context) => {
  const { directory, open } = await setupStore(context)
  const packagedJson = path.join(directory, 'packaged-notes.json')
  const developmentJson = path.join(directory, 'development-notes.json')

  await fs.writeFile(
    packagedJson,
    JSON.stringify({
      version: 1,
      notes: {
        '2026-08-28': {
          content: 'Older packaged note',
          updatedAt: '2026-08-28T10:00:00.000Z',
        },
      },
    }),
  )
  await fs.writeFile(
    developmentJson,
    JSON.stringify({
      version: 1,
      notes: {
        '2026-08-28': {
          content: 'Newer development note',
          updatedAt: '2026-08-28T11:00:00.000Z',
        },
        '2026-08-29': { content: 'Future note', updatedAt: null },
      },
    }),
  )

  const store = await open({ legacyPaths: [packagedJson, developmentJson] })
  assert.equal(store.get('2026-08-28').content, 'Newer development note')
  assert.equal(store.get('2026-08-29').content, 'Future note')

  await store.save('2026-08-28', 'Edited in SQLite')
  store.close()

  const reloaded = await open({ legacyPaths: [packagedJson, developmentJson] })
  assert.equal(reloaded.get('2026-08-28').content, 'Edited in SQLite')
  await fs.access(packagedJson)
  await fs.access(developmentJson)
})

test('escapes note content before rendering it into the editor', () => {
  const malicious = '\"><img src=x onerror=alert(1)>'
  const rendered = daySection('2026-08-28', { content: malicious })

  assert.equal(rendered.includes(malicious), false)
  assert.equal(rendered.includes('&lt;img'), true)
  assert.equal(rendered.includes('ADD LINK'), false)
  assert.equal(escapeHtml('A & B'), 'A &amp; B')
})

test('renders saved lists and URLs as editable rich content', () => {
  const rendered = renderNoteHtml(
    '- First item\n- Read https://example.com\n\n1. One\n2. Two',
  )

  assert.match(rendered, /<ul><li>First item<\/li>/)
  assert.match(rendered, /<ol><li>One<\/li><li>Two<\/li><\/ol>/)
  assert.match(rendered, /<a href="https:\/\/example.com"/)
  assert.match(rendered, />https:\/\/example.com<\/a>/)
  assert.equal(renderNoteHtml(''), '<ul><li><br></li></ul>')
})

test('renders indented lines as nested lists', () => {
  assert.equal(
    renderNoteHtml('- Groceries\n  - Apples\n  - Pears\n    1. Conference\n- Call Anna'),
    '<ul><li>Groceries<ul><li>Apples</li><li>Pears<ol><li>Conference</li></ol></li></ul></li><li>Call Anna</li></ul>',
  )
  assert.equal(
    renderNoteHtml('- Plan\n  -\n  - Later'),
    '<ul><li>Plan<ul><li><br></li><li>Later</li></ul></li></ul>',
  )
  assert.equal(
    renderNoteHtml('    - Too deep\n- Back'),
    '<ul><li>Too deep</li><li>Back</li></ul>',
  )
})

test('renders standalone X and Twitter links as clickable post previews', () => {
  const rendered = renderNoteHtml(
    '- https://x.com/Hewar/status/1234567890123456789\n- https://twitter.com/dhh/status/9876543210987654321?ref=test\n- Read https://x.com/Hewar/status/1234567890123456789',
  )

  assert.match(rendered, /class="note-tweet-item"/)
  assert.match(rendered, /data-tweet-id="1234567890123456789"/)
  assert.match(rendered, /data-tweet-user="Hewar"/)
  assert.match(rendered, /data-tweet-url="https:\/\/twitter\.com\/dhh\/status\/9876543210987654321\?ref=test"/)
  assert.match(rendered, /class="tweet-preview-embed"/)
  assert.match(rendered, /class="tweet-preview-link"/)
  assert.match(rendered, /data-url="https:\/\/x\.com\/Hewar\/status\/1234567890123456789"/)
  assert.match(rendered, /aria-label="Open post by @Hewar on X"/)
  assert.equal((rendered.match(/class="note-tweet-item"/g) || []).length, 2)
  assert.match(rendered, /Read <a href="https:\/\/x\.com\/Hewar\/status\/1234567890123456789"/)
})

test('renders stored image references inside a daily note', () => {
  const id = 'a'.repeat(64)
  const rendered = renderNoteHtml(`- ![Screenshot](noterepo:image:${id})`)

  assert.match(rendered, new RegExp(`src="/api/images/${id}"`))
  assert.match(rendered, new RegExp(`data-image-id="${id}"`))
  assert.match(rendered, /class="note-image"/)
  assert.match(rendered, /class="note-image-item"/)
  assert.match(rendered, /draggable="true"/)
  assert.match(rendered, /title="Click to select\. Drag to move\."/)
  assert.match(rendered, /alt="Screenshot"/)
})

test('extracts a clean page title for pasted links', () => {
  assert.equal(
    extractPageTitle(
      '<head><title>How to keep enjoying programming in a world of LLMs | Hacker News</title></head>',
      'https://news.ycombinator.com/item?id=49854875',
    ),
    'How to keep enjoying programming in a world of LLMs',
  )
  assert.equal(
    extractPageTitle(
      `<head><title>Ignored</title><meta content="Tom &amp; Jerry&#39;s &quot;guide&quot;" property='og:title'></head>`,
      'https://flaviocopes.com/guide',
    ),
    'Tom & Jerry\'s "guide"',
  )
  assert.equal(
    extractPageTitle(
      '<title>Rust (programming language) - Wikipedia</title>',
      'https://en.wikipedia.org/wiki/Rust_(programming_language)',
    ),
    'Rust (programming language)',
  )
  assert.equal(
    extractPageTitle(
      '<meta name="og:site_name" content="The Daily Paper"><title>\n  Rates rise again — The Daily Paper\n</title>',
      'https://dailypaper.news/rates',
    ),
    'Rates rise again',
  )
  assert.equal(
    extractPageTitle('<title>Python 3.14 - What is new</title>', 'https://docs.python.org/3/'),
    'Python 3.14 - What is new',
  )
  assert.equal(extractPageTitle('<head></head>', 'https://flaviocopes.com'), null)
})

test('fetches the title of a pasted web page', async (context) => {
  const page = http.createServer((request, response) => {
    if (request.url === '/moved') {
      response.writeHead(302, { Location: '/article' })
      response.end()
      return
    }
    if (request.url === '/image.png') {
      response.writeHead(200, { 'Content-Type': 'image/png' })
      response.end(PIXEL_PNG)
      return
    }
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    response.end('<html><head><title>Caffè notes | Flavio</title></head><body></body></html>')
  })
  await new Promise((resolve) => page.listen(0, '127.0.0.1', resolve))
  const pageOrigin = `http://127.0.0.1:${page.address().port}`
  const app = createAppServer({ distDir: os.tmpdir(), store: null })
  const appUrl = await app.listen()
  context.after(async () => {
    await app.close()
    await new Promise((resolve) => page.close(resolve))
  })

  const linkTitle = async (url) => {
    const response = await fetch(`${appUrl}/api/link-title?url=${encodeURIComponent(url)}`)
    return { status: response.status, body: response.ok ? await response.json() : null }
  }

  assert.deepEqual(await linkTitle(`${pageOrigin}/moved`), {
    status: 200,
    body: { title: 'Caffè notes' },
  })
  assert.deepEqual(await linkTitle(`${pageOrigin}/image.png`), {
    status: 200,
    body: { title: null },
  })
  assert.equal((await linkTitle('file:///etc/hosts')).status, 400)
  assert.equal((await linkTitle('not a link')).status, 400)
})

test('merges an editor save with a change made outside the app', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()
  await store.save('2026-09-20', '- A\n- B')
  const app = createAppServer({ distDir: os.tmpdir(), store })
  const appUrl = await app.listen()
  context.after(() => app.close())

  store.put('2026-09-20', '- A\n- B\n- Added by an agent')
  const response = await fetch(`${appUrl}/api/day/2026-09-20`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: '- A edited\n- B', base: '- A\n- B' }),
  })
  const saved = await response.json()

  assert.equal(saved.content, '- A edited\n- B\n- Added by an agent')
  assert.match(saved.html, /Added by an agent/)
  assert.equal(store.get('2026-09-20').content, saved.content)

  const note = await (await fetch(`${appUrl}/api/day/2026-09-20?format=json`)).json()
  assert.equal(note.content, saved.content)
  assert.equal(note.hasContent, true)
  assert.match(note.html, /<ul><li>A edited<\/li>/)
})

test('notices notes written by another connection', async (context) => {
  const { open } = await setupStore(context)
  const app = await open()
  const agent = await open()
  const version = app.dataVersion()

  await agent.save('2026-09-21', '- From the CLI')
  assert.notEqual(app.dataVersion(), version)
  assert.equal(typeof app.versions().get('2026-09-21'), 'string')
  assert.deepEqual(
    app.days({ limit: 5 }).map((note) => note.date),
    ['2026-09-21'],
  )
})

test('backs up, empties and restores every note and image', async (context) => {
  const { directory, open } = await setupStore(context)
  const store = await open()
  await store.save('2026-09-22', '- Keep me')
  store.saveImage({ data: PIXEL_PNG, mimeType: 'image/png', fileName: 'pixel.png' })
  const backup = path.join(directory, 'backups', 'one', 'notes.sqlite3')

  await store.backup(backup)
  store.clearAll()
  assert.deepEqual(store.stats(), { days: 0, firstDay: null, lastDay: null, images: 0 })

  await store.restore(backup)
  assert.deepEqual(store.stats(), { days: 1, firstDay: '2026-09-22', lastDay: '2026-09-22', images: 1 })
  assert.equal(store.get('2026-09-22').content, '- Keep me')
  assert.equal((await fs.stat(backup)).mode & 0o777, 0o600)
})

test('checks image bytes before storing an upload', () => {
  assert.equal(hasImageSignature(PIXEL_PNG, 'image/png'), true)
  assert.equal(hasImageSignature(Buffer.from('not an image'), 'image/png'), false)
  assert.equal(
    hasImageSignature(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>'), 'image/svg+xml'),
    true,
  )
  assert.equal(
    hasImageSignature(Buffer.from('<svg><script>alert(1)</script></svg>'), 'image/svg+xml'),
    false,
  )
})

test('converts Reflect daily documents into NoteRepo content', () => {
  const id = 'b'.repeat(64)
  const document = {
    type: 'doc',
    content: [
      { type: 'heading', content: [{ type: 'text', text: 'Daily title' }] },
      {
        type: 'list',
        attrs: { kind: 'bullet' },
        content: [{ type: 'paragraph', content: [{ type: 'text', text: 'Buy milk' }] }],
      },
      {
        type: 'list',
        attrs: { kind: 'ordered' },
        content: [
          {
            type: 'paragraph',
            content: [
              {
                type: 'text',
                text: 'Reflect',
                marks: [{ type: 'link', attrs: { href: 'https://reflect.app' } }],
              },
            ],
          },
        ],
      },
      {
        type: 'image',
        attrs: { src: 'https://reflect-assets.app/image.png', fileName: 'image.png' },
      },
      { type: 'tweet', attrs: { url: 'https://x.com/flaviocopes/status/1' } },
    ],
  }
  const images = new Map([
    ['https://reflect-assets.app/image.png', { id, fileName: 'image.png' }],
  ])

  assert.equal(
    documentToContent(document, images),
    `- Buy milk\n1. [Reflect](https://reflect.app)\n![image.png](noterepo:image:${id})\nhttps://x.com/flaviocopes/status/1`,
  )
  assert.equal(detectImageMime(PIXEL_PNG, 'application/octet-stream'), 'image/png')
  assert.equal(
    validateReflectImageUrl('https://reflect-assets.app/image.png'),
    'https://reflect-assets.app/image.png',
  )
  assert.throws(() => validateReflectImageUrl('http://127.0.0.1/image.png'))
})

test('merges Reflect imports without overwriting or duplicating notes', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()
  await store.save('2026-08-19', 'Kept from NoteRepo')

  const notes = [
    { date: '2026-08-19', content: 'Imported from Reflect', updatedAt: null },
    { date: '2026-08-20', content: 'A new Reflect note', updatedAt: null },
    { date: '2026-08-21', content: '', updatedAt: null },
  ]
  assert.deepEqual(importNotes(store.database, notes), {
    imported: 1,
    merged: 1,
    unchanged: 0,
    empty: 1,
  })
  assert.equal(
    store.get('2026-08-19').content,
    'Kept from NoteRepo\n\nImported from Reflect',
  )

  assert.deepEqual(importNotes(store.database, notes), {
    imported: 0,
    merged: 0,
    unchanged: 2,
    empty: 1,
  })
})

test('upgrades imported Reflect image URLs without duplicating their notes', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()
  const source = 'https://reflect-assets.app/image.svg'
  const id = 'c'.repeat(64)
  await store.save('2026-08-22', `Before\n${source}\nAfter`)

  assert.equal(
    upgradeImageReferences(
      store.database,
      new Map([[source, { id, fileName: 'diagram.svg' }]]),
    ),
    1,
  )
  assert.equal(
    store.get('2026-08-22').content,
    `Before\n![diagram.svg](noterepo:image:${id})\nAfter`,
  )
})

test('formats daily headings like the reference', () => {
  assert.equal(dayTitle(new Date(2026, 7, 1)), 'Sat, August 1st, 2026')
  assert.equal(dayTitle(new Date(2026, 7, 2)), 'Sun, August 2nd, 2026')
  assert.equal(dayTitle(new Date(2026, 7, 3)), 'Mon, August 3rd, 2026')
  assert.equal(dayTitle(new Date(2026, 7, 6)), 'Thu, August 6th, 2026')
  assert.equal(dayTitle(new Date(2026, 7, 11)), 'Tue, August 11th, 2026')
  assert.equal(dayTitle(new Date(2026, 7, 21)), 'Fri, August 21st, 2026')
})

const dayFromToday = (amount) => {
  const date = new Date()
  date.setDate(date.getDate() + amount)
  const pad = (value) => String(value).padStart(2, '0')
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

const feedDates = (html) => [...html.matchAll(/data-note-date="([^"]+)"/g)].map((match) => match[1])

test('opens on today after the past days that have notes', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()
  const today = todayKey()

  await store.save(dayFromToday(-10), 'Earlier note')
  await store.save(dayFromToday(-5), ' \n\t ')
  await store.save(dayFromToday(-2), '- ')
  await store.save(dayFromToday(-1), 'Yesterday note')
  await store.save(dayFromToday(1), 'Future note')

  const initial = feedInitial(store, today)
  assert.deepEqual(feedDates(initial), [dayFromToday(-10), dayFromToday(-1), today])
  assert.match(initial, new RegExp(`before=${dayFromToday(-10)}`))
  assert.doesNotMatch(initial, /after=/)
  assert.match(initial, new RegExp(`class="day-note is-today"\\s+data-note-date="${today}"`))
  assert.equal(feedInitial(store, dayFromToday(3)), initial)

  const fresh = feedInitial(await (await setupStore(context)).open(), today)
  assert.deepEqual(feedDates(fresh), [today])
})

test('loads past days with notes around a jumped-to date', async (context) => {
  const { open } = await setupStore(context)
  const store = await open()
  const today = todayKey()

  await store.save(dayFromToday(-40), 'First note')
  await store.save(dayFromToday(-30), 'Second note')
  await store.save(dayFromToday(-20), 'Third note')

  assert.deepEqual(feedDates(feedInitial(store, dayFromToday(-30))), [
    dayFromToday(-40),
    dayFromToday(-30),
    dayFromToday(-20),
    today,
  ])
  assert.deepEqual(feedDates(feedInitial(store, dayFromToday(-35))), [
    dayFromToday(-40),
    dayFromToday(-30),
    dayFromToday(-20),
    today,
  ])

  const later = feedAfter(store, dayFromToday(-45), 2)
  assert.deepEqual(feedDates(later), [dayFromToday(-40), dayFromToday(-30)])
  assert.match(later, new RegExp(`after=${dayFromToday(-30)}`))
  assert.deepEqual(feedDates(feedAfter(store, dayFromToday(-30), 2)), [dayFromToday(-20), today])

  const earlier = feedBefore(store, dayFromToday(-30))
  assert.deepEqual(feedDates(earlier), [dayFromToday(-40)])
  assert.match(earlier, new RegExp(`before=${dayFromToday(-40)}`))
  assert.equal(feedBefore(store, dayFromToday(-40)), '')
})
