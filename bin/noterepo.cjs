#!/usr/bin/env node
const fs = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const { createHash } = require('node:crypto')
const { execFileSync } = require('node:child_process')
const { IMAGE_MIME_TYPES, MAX_IMAGE_BYTES, NoteStore, isDateKey } = require('../electron/store.cjs')
const { dayTitle, hasImageSignature, todayKey } = require('../electron/server.cjs')
const { fetchLinkTitle, linkText, tweetDetails } = require('../electron/links.cjs')
const {
  cleanText,
  describeOutline,
  inputEntries,
  parseOutline,
  serializeOutline,
  subtreeEnd,
} = require('../electron/outline.cjs')
const { version } = require('../package.json')

const HELP = `noterepo ${version}, the NoteRepo companion CLI for agents

Every command prints JSON. Errors print {"error": "..."} to stderr and exit
with 1, or 2 for a wrong command or option.

A day is a list of items. Each item has a number (n), a level (0 for top
level, 1 for nested under the item before it, and so on), a list type
(bullet or numbered) and its text. Commands that take N use the n shown by
"show". Removing or moving an item takes its nested items with it.

DATE is YYYY-MM-DD, "today" or "yesterday". NoteRepo has no future days, so
commands that write only accept today and earlier days.

Read
  info                            Data folder, database, app status and counts
  days [--from DATE] [--to DATE] [--limit N]
                                  Days with notes, newest first (limit 30, 0 for all)
  show [DATE]                     Every item of a day (default today)
  search QUERY                    Days and items containing QUERY
  title URL                       The link text NoteRepo shows for URL

Write
  add TEXT [--date DATE] [--after N | --before N] [--level L] [--numbered | --bullet] [--raw]
                                  Add one item, at the end of the day by default.
                                  A URL on its own gets its page title, like pasting it.
                                  X posts stay as URLs so the app shows a preview.
  image FILE [--date DATE] [--after N | --before N] [--level L]
                                  Add a PNG, JPEG, GIF, WebP or SVG image
  edit N [TEXT] [--date DATE] [--level L] [--numbered | --bullet] [--raw]
                                  Change the text, level or list type of an item
  remove N... [--date DATE]       Delete items
  move N [--date DATE] [--to DATE] [--after M | --before M] [--level L]
                                  Move an item within a day or to another day
  write [DATE] [--content TEXT] [--append] [--raw]
                                  Replace a day with Markdown list lines from
                                  --content or stdin. --append adds them instead.
  write --json [--content JSON] [--append] [--raw]
                                  Write many days at once from an object like
                                  {"2026-09-28": "- Plan\\n  1. Write"} (strings or arrays of lines)
  clear DATE                      Delete everything written on a day

App
  open [DATE]                     Bring NoteRepo to the front on a day

Safety
  backup [--to DIR]               Save a copy of every note and image
  reset --yes                     Back up, then empty the notebook
  restore PATH --yes              Back up, then replace every note with a backup
                                  (a backup folder or a notes.sqlite3 file)

Options for every command
  --data-dir DIR                  Use another data folder (or NOTEREPO_DATA_DIR).
                                  Pair it with the app's --user-data-dir.
  --help, --version

Changes show up in the running app within a second.`

class CliError extends Error {
  constructor(message, exitCode = 1) {
    super(message)
    this.exitCode = exitCode
  }
}

const usage = (message) => new CliError(`${message}. Run "noterepo help" for the commands`, 2)

const parseOptions = (args, options) => {
  const values = {}
  const positionals = []
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (arg === '--') {
      positionals.push(...args.slice(index + 1))
      break
    }
    const match = arg.match(/^--([a-z-]+)(?:=([\s\S]*))?$/)
    if (!match) {
      positionals.push(arg)
      continue
    }
    const [, name, inline] = match
    const option = options[name]
    if (!option) throw usage(`Unknown option --${name}`)
    if (option.type === 'boolean') {
      if (inline !== undefined) throw usage(`--${name} doesn't take a value`)
      values[name] = true
      continue
    }
    const value = inline ?? args[index + 1]
    if (value === undefined) throw usage(`--${name} needs a value`)
    if (inline === undefined) index += 1
    values[name] = value
  }
  return { values, positionals }
}

const COMMON = {
  'data-dir': { type: 'string' },
  help: { type: 'boolean' },
}
const DATE = { date: { type: 'string' } }
const POSITION = { after: { type: 'string' }, before: { type: 'string' }, level: { type: 'string' } }
const LIST = { numbered: { type: 'boolean' }, bullet: { type: 'boolean' } }
const RAW = { raw: { type: 'boolean' } }

const pad = (value) => String(value).padStart(2, '0')

const dateKey = (date) => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`

const fromDateKey = (value) => {
  const [year, month, day] = value.split('-').map(Number)
  return new Date(year, month - 1, day)
}

const parseDate = (value = 'today', { writing = false } = {}) => {
  let date = value
  if (value === 'today') date = todayKey()
  if (value === 'yesterday') {
    const yesterday = new Date()
    yesterday.setDate(yesterday.getDate() - 1)
    date = dateKey(yesterday)
  }
  if (!isDateKey(date)) throw usage(`"${value}" isn't a date. Use YYYY-MM-DD, today or yesterday`)
  if (writing && date > todayKey()) {
    throw new CliError(`${date} is in the future. NoteRepo only keeps notes for today and earlier days`)
  }
  return date
}

const parseNumber = (value, name, minimum = 1) => {
  if (value === undefined) return undefined
  if (!/^\d+$/.test(value) || Number(value) < minimum) {
    throw usage(`${name} must be a whole number${minimum ? ' from 1' : ''}, not "${value}"`)
  }
  return Number(value)
}

const readStdin = async () => {
  if (process.stdin.isTTY) return ''
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  return Buffer.concat(chunks).toString('utf8')
}

const plainText = (text) =>
  text
    .replace(/!\[[^\]]*\]\(noterepo:image:[a-f0-9]{64}\)/gi, '[Image]')
    .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/gi, '$1')

const dayOutput = (store, date) => {
  const { content, updatedAt } = store.get(date)
  return {
    date,
    title: dayTitle(fromDateKey(date)),
    updatedAt,
    items: describeOutline(parseOutline(content)),
    content,
  }
}

const itemIndexes = (entries) =>
  entries.flatMap((entry, index) => (entry.body.trim() ? [index] : []))

const findItem = (entries, n) => {
  const indexes = itemIndexes(entries)
  const index = indexes[n - 1]
  if (index === undefined) {
    throw new CliError(`Item ${n} doesn't exist. This day has ${indexes.length} item${indexes.length === 1 ? '' : 's'}`)
  }
  return index
}

const listOptions = (values) => {
  if (values.numbered && values.bullet) throw usage('Pass --numbered or --bullet, not both')
  if (values.after !== undefined && values.before !== undefined) throw usage('Pass --after or --before, not both')
  return {
    after: parseNumber(values.after, '--after'),
    before: parseNumber(values.before, '--before'),
    level: parseNumber(values.level, '--level', 0),
    numbered: values.numbered,
    bullet: values.bullet,
  }
}

const insertionPoint = (entries, { after, before }) => {
  if (after !== undefined) {
    const index = findItem(entries, after)
    return { index: subtreeEnd(entries, index), level: entries[index].depth }
  }
  if (before !== undefined) {
    const index = findItem(entries, before)
    return { index, level: entries[index].depth }
  }
  let index = entries.length
  while (index > 0 && !entries[index - 1].body.trim()) index -= 1
  return { index, level: 0 }
}

const checkLevel = (entries, index, level) => {
  const deepest = index === 0 ? 0 : entries[index - 1].depth + 1
  if (level > deepest) {
    throw new CliError(`Level ${level} is too deep there. The deepest level allowed at that position is ${deepest}`)
  }
}

const listType = (entries, index, level, { numbered, bullet }) => {
  if (numbered) return true
  if (bullet) return false
  for (let previous = index - 1; previous >= 0 && entries[previous].depth >= level; previous -= 1) {
    if (entries[previous].depth === level) return entries[previous].ordered
  }
  const next = entries[index]
  return Boolean(next && next.depth === level && next.ordered)
}

const place = (entries, subtree, options) => {
  const point = insertionPoint(entries, options)
  const level = options.level ?? point.level
  checkLevel(entries, point.index, level)
  const [root] = subtree
  const shift = level - root.depth
  for (const entry of subtree) {
    entry.depth += shift
    entry.dirty = true
  }
  root.ordered = listType(entries, point.index, level, options)
  const next = entries[point.index]
  root.start = root.ordered && next?.ordered && next.depth === level ? next.start : 1
  entries.splice(point.index, 0, ...subtree)
}

const detach = (entries, index) => {
  const removed = entries.splice(index, subtreeEnd(entries, index) - index)
  const next = entries[index]
  if (removed[0].ordered && next?.ordered && next.depth === removed[0].depth && next.start !== removed[0].start) {
    next.start = removed[0].start
    next.dirty = true
  }
  return removed
}

const isBareUrl = (value) => /^https?:\/\/\S+$/i.test(value)

const titled = async (value, raw) => {
  if (raw || !isBareUrl(value) || tweetDetails(value)) return value
  const title = await fetchLinkTitle(value)
  return title ? linkText(value, title) : value
}

const itemText = async (words, raw) => {
  const joined = words.length === 1 && words[0] === '-' ? await readStdin() : words.join(' ')
  const text = cleanText(joined).trim()
  if (text.includes('\n')) throw usage('An item is one line. Use "write --append" to add several lines')
  const [entry] = inputEntries(text)
  if (!entry) throw usage('Pass the text of the item')
  return { body: await titled(entry.body, raw), ordered: entry.ordered }
}

const withTitles = async (entries, raw) => {
  const pending = entries.filter((entry) => isBareUrl(entry.body))
  for (let start = 0; start < pending.length; start += 6) {
    await Promise.all(
      pending.slice(start, start + 6).map(async (entry) => {
        entry.body = await titled(entry.body, raw)
      }),
    )
  }
  return entries
}

const writeEntries = (store, date, entries, append) => {
  const current = append ? parseOutline(store.get(date).content) : []
  const point = insertionPoint(current, {})
  let previousDepth = point.index ? current[point.index - 1].depth : -1
  for (const entry of entries) {
    entry.depth = Math.min(entry.depth, previousDepth + 1)
    previousDepth = entry.depth
  }
  current.splice(point.index, 0, ...entries)
  store.put(date, serializeOutline(current))
}

const linesFrom = async (text, raw, label) => {
  const entries = inputEntries(text)
  if (!entries.length) throw usage(`Pass the lines ${label}. To empty a day use "clear"`)
  return withTitles(entries, raw)
}

const imageMime = (data) => [...IMAGE_MIME_TYPES].find((mimeType) => hasImageSignature(data, mimeType))

const cleanImageAlt = (value) => value.replace(/[\[\]\r\n]/g, ' ').trim().slice(0, 240) || 'Image'

const runningApp = () => {
  try {
    const processes = execFileSync('ps', ['-Ao', 'pid=,comm='], { encoding: 'utf8' })
    for (const line of processes.split('\n')) {
      const [, pid, command] = line.match(/^\s*(\d+)\s+(.*)$/) || []
      if (Number(pid) === process.pid || !command?.endsWith('/NoteRepo.app/Contents/MacOS/NoteRepo')) continue
      return command.slice(0, -'/Contents/MacOS/NoteRepo'.length)
    }
  } catch {}
  return null
}

const sha256 = async (filePath) => createHash('sha256').update(await fs.readFile(filePath)).digest('hex')

const timestamp = () => {
  const now = new Date()
  return `${dateKey(now)}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
}

const exists = async (filePath) => Boolean(await fs.stat(filePath).catch(() => null))

const backupFolder = async (dataDir, label) => {
  const name = [timestamp(), label].filter(Boolean).join('-')
  let folder = path.join(dataDir, 'backups', name)
  for (let copy = 2; await exists(folder); copy += 1) folder = path.join(dataDir, 'backups', `${name}-${copy}`)
  return folder
}

const backup = async (store, dataDir, { to, label } = {}) => {
  const folder = to ? path.resolve(to) : await backupFolder(dataDir, label)
  const database = path.join(folder, 'notes.sqlite3')
  if (await exists(database)) throw new CliError(`${database} already exists`)
  await store.backup(database)
  const { days, images } = store.stats()
  return { path: folder, database, sha256: await sha256(database), days, images }
}

const commands = {
  info: {
    run: async ({ store, dataDir }) => {
      const app = runningApp()
      return {
        version,
        dataDir,
        database: store.filePath,
        backups: path.join(dataDir, 'backups'),
        app: { running: Boolean(app), path: app },
        ...store.stats(),
      }
    },
  },

  days: {
    options: { from: { type: 'string' }, to: { type: 'string' }, limit: { type: 'string' } },
    run: async ({ store, values }) => {
      const limit = parseNumber(values.limit ?? '30', '--limit', 0)
      const days = store.days({
        from: values.from ? parseDate(values.from) : undefined,
        to: values.to ? parseDate(values.to) : undefined,
        limit: limit || -1,
      })
      return {
        days: days.map(({ date, content }) => {
          const items = describeOutline(parseOutline(content))
          return { date, title: dayTitle(fromDateKey(date)), items: items.length, preview: plainText(items[0]?.text || '').slice(0, 100) }
        }),
      }
    },
  },

  show: {
    run: async ({ store, positionals }) => dayOutput(store, parseDate(positionals[0])),
  },

  search: {
    run: async ({ store, positionals }) => {
      const query = positionals.join(' ').trim()
      if (!query) throw usage('Pass something to search for')
      const needle = query.toLowerCase()
      return {
        query,
        results: store.search(query).map(({ date, content }) => ({
          date,
          title: dayTitle(fromDateKey(date)),
          items: describeOutline(parseOutline(content)).filter((item) => item.text.toLowerCase().includes(needle)),
        })),
      }
    },
  },

  title: {
    run: async ({ positionals }) => {
      const [url] = positionals
      if (!url || !isBareUrl(url)) throw usage('Pass a web link starting with http:// or https://')
      if (tweetDetails(url)) return { url, title: null, text: url, preview: 'x-post' }
      const title = await fetchLinkTitle(url)
      return { url, title, text: title ? linkText(url, title) : url }
    },
  },

  add: {
    options: { ...DATE, ...POSITION, ...LIST, ...RAW },
    run: async ({ store, values, positionals }) => {
      const date = parseDate(values.date, { writing: true })
      const options = listOptions(values)
      const { body, ordered } = await itemText(positionals, values.raw)
      if (ordered && !options.bullet) options.numbered = true
      store.transaction(() => {
        const entries = parseOutline(store.get(date).content)
        place(entries, [{ depth: 0, ordered: false, start: 1, body, raw: '', dirty: true }], options)
        store.put(date, serializeOutline(entries))
      })
      return dayOutput(store, date)
    },
  },

  image: {
    options: { ...DATE, ...POSITION, ...LIST },
    run: async ({ store, values, positionals }) => {
      const date = parseDate(values.date, { writing: true })
      const options = listOptions(values)
      const [file] = positionals
      if (!file) throw usage('Pass the image file')
      const stat = await fs.stat(file).catch(() => null)
      if (!stat?.isFile()) throw new CliError(`${file} isn't a file`)
      if (stat.size > MAX_IMAGE_BYTES) throw new CliError(`${file} is larger than 15 MB`)
      const data = await fs.readFile(file)
      const mimeType = imageMime(data)
      if (!mimeType) throw new CliError(`${file} isn't a PNG, JPEG, GIF, WebP or safe SVG image`)
      const alt = cleanImageAlt(path.basename(file))
      store.transaction(() => {
        const image = store.saveImage({ data, mimeType, fileName: alt })
        const entries = parseOutline(store.get(date).content)
        const body = `![${alt}](noterepo:image:${image.id})`
        place(entries, [{ depth: 0, ordered: false, start: 1, body, raw: '', dirty: true }], options)
        store.put(date, serializeOutline(entries))
      })
      return dayOutput(store, date)
    },
  },

  edit: {
    options: { ...DATE, level: { type: 'string' }, ...LIST, ...RAW },
    run: async ({ store, values, positionals }) => {
      const date = parseDate(values.date, { writing: true })
      const [position, ...words] = positionals
      const n = parseNumber(position, 'N')
      if (!n) throw usage('Pass the number of the item to edit')
      const options = listOptions(values)
      if (!words.length && options.level === undefined && !options.numbered && !options.bullet) {
        throw usage('Pass new text, --level, --numbered or --bullet')
      }
      const text = words.length ? await itemText(words, values.raw) : null
      if (text?.ordered && !options.bullet) options.numbered = true
      store.transaction(() => {
        const entries = parseOutline(store.get(date).content)
        const index = findItem(entries, n)
        const entry = entries[index]
        if (text) entry.body = text.body
        if (options.numbered || options.bullet) {
          entry.ordered = Boolean(options.numbered)
          entry.start = 1
        }
        if (options.level !== undefined) {
          checkLevel(entries, index, options.level)
          const shift = options.level - entry.depth
          for (const nested of entries.slice(index, subtreeEnd(entries, index))) {
            nested.depth += shift
            nested.dirty = true
          }
        }
        entry.dirty = true
        store.put(date, serializeOutline(entries))
      })
      return dayOutput(store, date)
    },
  },

  remove: {
    options: DATE,
    run: async ({ store, values, positionals }) => {
      const date = parseDate(values.date, { writing: true })
      if (!positionals.length) throw usage('Pass the numbers of the items to remove')
      const numbers = positionals.map((value) => parseNumber(value, 'N'))
      store.transaction(() => {
        const entries = parseOutline(store.get(date).content)
        const targets = numbers.map((n) => entries[findItem(entries, n)])
        for (const target of targets) {
          const index = entries.indexOf(target)
          if (index !== -1) detach(entries, index)
        }
        store.put(date, serializeOutline(entries))
      })
      return dayOutput(store, date)
    },
  },

  move: {
    options: { ...DATE, to: { type: 'string' }, ...POSITION, ...LIST },
    run: async ({ store, values, positionals }) => {
      const date = parseDate(values.date, { writing: true })
      const target = values.to ? parseDate(values.to, { writing: true }) : date
      const n = parseNumber(positionals[0], 'N')
      if (!n) throw usage('Pass the number of the item to move')
      const options = listOptions(values)
      store.transaction(() => {
        const source = parseOutline(store.get(date).content)
        const destination = target === date ? source : parseOutline(store.get(target).content)
        const moving = source[findItem(source, n)]
        const reference = options.after ?? options.before
        const anchor = reference === undefined ? null : destination[findItem(destination, reference)]
        const subtree = detach(source, source.indexOf(moving))
        if (anchor && subtree.includes(anchor)) throw new CliError('An item can\'t move inside itself')

        const position = { ...options }
        const anchorNumber = anchor ? itemIndexes(destination).indexOf(destination.indexOf(anchor)) + 1 : undefined
        if (options.after !== undefined) position.after = anchorNumber
        if (options.before !== undefined) position.before = anchorNumber
        place(destination, subtree, position)

        store.put(date, serializeOutline(source))
        if (target !== date) store.put(target, serializeOutline(destination))
      })
      return target === date ? dayOutput(store, date) : { from: dayOutput(store, date), to: dayOutput(store, target) }
    },
  },

  write: {
    options: { content: { type: 'string' }, json: { type: 'boolean' }, append: { type: 'boolean' }, ...RAW },
    run: async ({ store, values, positionals }) => {
      const text = values.content ?? (await readStdin())

      if (values.json) {
        let days
        try {
          days = JSON.parse(text)
        } catch {
          throw usage('--json needs an object like {"2026-09-28": "- Plan"}')
        }
        if (!days || typeof days !== 'object' || Array.isArray(days)) {
          throw usage('--json needs an object like {"2026-09-28": "- Plan"}')
        }
        const prepared = []
        for (const [key, value] of Object.entries(days)) {
          const lines = Array.isArray(value) ? value.join('\n') : value
          if (typeof lines !== 'string') throw usage(`The value for ${key} must be a string or an array of lines`)
          prepared.push({ date: parseDate(key, { writing: true }), entries: await linesFrom(lines, values.raw, `for ${key}`) })
        }
        store.transaction(() => {
          for (const { date, entries } of prepared) writeEntries(store, date, entries, values.append)
        })
        return {
          days: prepared.map(({ date }) => ({
            date,
            title: dayTitle(fromDateKey(date)),
            items: describeOutline(parseOutline(store.get(date).content)).length,
          })),
        }
      }

      const date = parseDate(positionals[0], { writing: true })
      const entries = await linesFrom(text, values.raw, 'with --content or stdin')
      store.transaction(() => writeEntries(store, date, entries, values.append))
      return dayOutput(store, date)
    },
  },

  clear: {
    run: async ({ store, positionals }) => {
      if (!positionals[0]) throw usage('Pass the date to clear')
      const date = parseDate(positionals[0], { writing: true })
      store.put(date, '')
      return { date, cleared: true }
    },
  },

  open: {
    run: async ({ positionals }) => {
      const date = positionals[0] ? parseDate(positionals[0]) : 'today'
      if (date !== 'today' && date > todayKey()) throw new CliError(`${date} is in the future`)
      const url = date === 'today' ? 'noterepo://today' : `noterepo://day/${date}`
      const app = runningApp()
      try {
        execFileSync('open', app ? ['-a', app, url] : ['-b', 'com.flaviocopes.noterepo', url], { stdio: 'ignore' })
      } catch {
        throw new CliError('Could not open NoteRepo. Is it installed?')
      }
      return { opened: date === 'today' ? todayKey() : date, app: app || 'com.flaviocopes.noterepo' }
    },
  },

  backup: {
    options: { to: { type: 'string' } },
    run: async ({ store, dataDir, values }) => backup(store, dataDir, { to: values.to }),
  },

  reset: {
    options: { yes: { type: 'boolean' } },
    run: async ({ store, dataDir, values }) => {
      if (!values.yes) throw new CliError('reset empties the notebook after backing it up. Run it again with --yes', 2)
      const saved = await backup(store, dataDir, { label: 'before-reset' })
      store.clearAll()
      return { backup: saved, ...store.stats() }
    },
  },

  restore: {
    options: { yes: { type: 'boolean' } },
    run: async ({ store, dataDir, values, positionals }) => {
      const [source] = positionals
      if (!source) throw usage('Pass a backup folder or notes.sqlite3 file')
      if (!values.yes) {
        throw new CliError('restore replaces every note after backing them up. Run it again with --yes', 2)
      }
      const stat = await fs.stat(source).catch(() => null)
      const database = stat?.isDirectory() ? path.join(source, 'notes.sqlite3') : source
      if (!(await fs.stat(database).catch(() => null))?.isFile()) throw new CliError(`${database} doesn't exist`)
      const saved = await backup(store, dataDir, { label: 'before-restore' })
      try {
        await store.restore(path.resolve(database))
      } catch {
        throw new CliError(`${database} isn't a NoteRepo database. Your notes are unchanged`)
      }
      return { restored: { database: path.resolve(database), ...store.stats() }, backup: saved }
    },
  },
}

const defaultDataDir = () =>
  process.env.NOTEREPO_DATA_DIR || path.join(os.homedir(), 'Library', 'Application Support', 'NoteRepo')

const main = async () => {
  const args = process.argv.slice(2)
  let position = 0
  while (position < args.length && args[position].startsWith('-')) position += args[position] === '--data-dir' ? 2 : 1
  const name = args[position]
  const rest = [...args.slice(0, position), ...args.slice(position + 1)]
  if (args.includes('--version') || args.includes('-v')) return process.stdout.write(`${version}\n`)
  if (!name || name === 'help' || args.includes('-h')) return process.stdout.write(`${HELP}\n`)

  const command = commands[name]
  if (!command) throw usage(`"${name}" isn't a command`)

  const parsed = parseOptions(rest, { ...COMMON, ...command.options })
  if (parsed.values.help) return process.stdout.write(`${HELP}\n`)

  const dataDir = path.resolve(parsed.values['data-dir'] || defaultDataDir())
  const appData = path.join(os.homedir(), 'Library', 'Application Support')
  const store = await new NoteStore(path.join(dataDir, 'notes.sqlite3'), {
    legacyPaths: [path.join(dataDir, 'notes.json'), path.join(appData, 'noterepo', 'notes.json')],
  }).load()
  try {
    const result = await command.run({ store, dataDir, values: parsed.values, positionals: parsed.positionals })
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
  } finally {
    store.close()
  }
}

main().catch((error) => {
  const message = error instanceof CliError ? error.message : error.message || String(error)
  process.stderr.write(`${JSON.stringify({ error: message })}\n`)
  process.exitCode = error instanceof CliError ? error.exitCode : 1
})
