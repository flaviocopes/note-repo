const fs = require('node:fs/promises')
const path = require('node:path')
const { createHash } = require('node:crypto')
const { DatabaseSync } = require('node:sqlite')
const { NoteStore, MAX_IMAGE_BYTES } = require('../electron/store.cjs')
const { hasImageSignature } = require('../electron/server.cjs')

const IMAGE_MIME_TYPES = [
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
  'image/svg+xml',
]

const cleanText = (value) => String(value || '').replace(/[\r\n]+/g, ' ').trim()

const cleanImageAlt = (value) =>
  cleanText(value).replace(/[\[\]]/g, ' ').trim().slice(0, 240) || 'Reflect image'

const inlineContent = (node, images) => {
  if (!node || typeof node !== 'object') return ''
  if (node.type === 'hardBreak') return '\n'
  if (node.type === 'tag') return `#${cleanText(node.attrs?.label)}`
  if (node.type === 'backlink') return `[[${cleanText(node.attrs?.label)}]]`
  if (node.type === 'image') {
    const source = node.attrs?.src
    const image = source ? images.get(source) : null
    if (image) {
      return `![${cleanImageAlt(image.fileName)}](noterepo:image:${image.id})`
    }
    return typeof source === 'string' ? source : '[Image unavailable]'
  }
  if (node.type === 'text') {
    const text = String(node.text || '')
    const link = (node.marks || []).find(
      (mark) => mark.type === 'link' && /^https?:\/\//i.test(mark.attrs?.href || ''),
    )
    if (!link) return text
    const href = String(link.attrs.href)
    return text === href ? href : `[${text.replace(/[\[\]]/g, '')}](${href})`
  }
  return (node.content || []).map((child) => inlineContent(child, images)).join('')
}

const nodeLines = (node, images, depth = 0) => {
  if (!node || typeof node !== 'object') return []

  if (['paragraph', 'heading', 'codeBlock'].includes(node.type)) {
    return inlineContent(node, images).split('\n')
  }
  if (node.type === 'tweet') return node.attrs?.url ? [String(node.attrs.url)] : []
  if (node.type === 'iframe') return node.attrs?.src ? [String(node.attrs.src)] : []
  if (node.type === 'image') return [inlineContent(node, images)]
  if (node.type === 'horizontalRule') return ['—']
  if (node.type === 'blockquote') {
    return sequenceLines(node.content || [], images, depth).map((line) => `> ${line}`.trimEnd())
  }
  return sequenceLines(node.content || [], images, depth)
}

const listLines = (node, images, depth, order) => {
  const children = node.content || []
  const firstLines = children.length ? nodeLines(children[0], images, 0) : []
  const first = firstLines.shift() || ''
  const nestedLines = sequenceLines(children.slice(1), images, depth + 1)
  if (!first.trim() && !firstLines.some((line) => line.trim()) && !nestedLines.length) {
    return []
  }
  const kind = node.attrs?.kind
  const checked = node.attrs?.checked ? 'x' : ' '
  const marker =
    kind === 'ordered' ? `${order}.` : kind === 'checklist' ? `- [${checked}]` : '-'
  const indent = '  '.repeat(depth)
  const lines = [`${indent}${marker}${first ? ` ${first}` : ''}`]

  lines.push(...firstLines.map((line) => `${indent}  ${line}`.trimEnd()))
  lines.push(...nestedLines)
  return lines
}

function sequenceLines(nodes, images, depth = 0) {
  const lines = []
  let previousWasOrdered = false
  let order = 0

  for (const node of nodes) {
    if (node?.type === 'list') {
      const ordered = node.attrs?.kind === 'ordered'
      order = ordered
        ? Number.isInteger(node.attrs?.order)
          ? node.attrs.order
          : previousWasOrdered
            ? order + 1
            : 1
        : 0
      lines.push(...listLines(node, images, depth, order))
      previousWasOrdered = ordered
      continue
    }

    previousWasOrdered = false
    order = 0
    lines.push(...nodeLines(node, images, depth))
  }

  return lines
}

const documentToContent = (document, images = new Map()) => {
  const nodes = Array.isArray(document?.content) ? [...document.content] : []
  if (nodes[0]?.type === 'heading') nodes.shift()
  return sequenceLines(nodes, images)
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

const walkNodes = (node, visit) => {
  if (!node || typeof node !== 'object') return
  visit(node)
  for (const child of node.content || []) walkNodes(child, visit)
}

const loadReflectExport = async (sourcePath) => {
  const sourceData = await fs.readFile(sourcePath)
  const parsed = JSON.parse(sourceData.toString('utf8'))
  if (!Array.isArray(parsed.notes)) throw new TypeError('Reflect export has no notes array')

  const dailyNotes = []
  const seenDates = new Set()
  const imageSources = new Map()

  for (const note of parsed.notes) {
    if (!note.daily_at) continue
    if (!/^\d{4}-\d{2}-\d{2}$/.test(note.daily_at)) {
      throw new TypeError('Reflect export contains an invalid daily date')
    }
    if (seenDates.has(note.daily_at)) throw new TypeError(`Duplicate daily note: ${note.daily_at}`)
    seenDates.add(note.daily_at)

    const document = JSON.parse(note.document_json)
    dailyNotes.push({
      date: note.daily_at,
      document,
      updatedAt: note.updated_at || note.edited_at || null,
    })

    walkNodes(document, (node) => {
      if (node.type !== 'image' || typeof node.attrs?.src !== 'string') return
      if (!imageSources.has(node.attrs.src)) {
        imageSources.set(node.attrs.src, {
          url: node.attrs.src,
          fileName:
            node.attrs.fileName || node.attrs.alt || node.attrs.title || 'Reflect image',
          width: Number.isInteger(node.attrs.width) ? node.attrs.width : null,
          height: Number.isInteger(node.attrs.height) ? node.attrs.height : null,
        })
      }
    })
  }

  dailyNotes.sort((left, right) => left.date.localeCompare(right.date))
  return {
    checksum: createHash('sha256').update(sourceData).digest('hex'),
    dailyNotes,
    imageSources: [...imageSources.values()],
    totalNotes: parsed.notes.length,
    nonDailyNotes: parsed.notes.length - dailyNotes.length,
  }
}

const validateReflectImageUrl = (value) => {
  const url = new URL(value)
  const reflectHost =
    url.hostname === 'reflect-assets.app' || url.hostname.endsWith('.reflect-assets.app')
  if (url.protocol !== 'https:' || !reflectHost) {
    throw new TypeError('Image URL is not hosted by Reflect')
  }
  return url.href
}

const responseBuffer = async (response) => {
  const statedSize = Number(response.headers.get('content-length'))
  if (Number.isFinite(statedSize) && statedSize > MAX_IMAGE_BYTES) {
    throw new RangeError('Image is larger than 15 MB')
  }
  if (!response.body) throw new TypeError('Image response is empty')

  const chunks = []
  let size = 0
  for await (const chunk of response.body) {
    size += chunk.length
    if (size > MAX_IMAGE_BYTES) throw new RangeError('Image is larger than 15 MB')
    chunks.push(Buffer.from(chunk))
  }
  return Buffer.concat(chunks)
}

const detectImageMime = (data, contentType = '') => {
  const declared = contentType.split(';', 1)[0].trim().toLowerCase()
  const candidates = declared ? [declared, ...IMAGE_MIME_TYPES] : IMAGE_MIME_TYPES
  return [...new Set(candidates)].find(
    (mimeType) => IMAGE_MIME_TYPES.includes(mimeType) && hasImageSignature(data, mimeType),
  )
}

const downloadImage = async (source) => {
  const url = validateReflectImageUrl(source.url)
  const response = await fetch(url, {
    redirect: 'follow',
    signal: AbortSignal.timeout(30_000),
  })
  if (!response.ok) throw new Error(`Reflect returned HTTP ${response.status}`)
  const data = await responseBuffer(response)
  const mimeType = detectImageMime(data, response.headers.get('content-type') || '')
  if (!mimeType) throw new TypeError('Downloaded file is not a supported image')
  return { ...source, data, mimeType }
}

const downloadImages = async (sources, store, concurrency = 4) => {
  const imported = new Map()
  let nextIndex = 0
  let completed = 0
  let failed = 0

  const worker = async () => {
    while (nextIndex < sources.length) {
      const index = nextIndex
      nextIndex += 1
      const source = sources[index]
      try {
        const image = await downloadImage(source)
        const saved = store.saveImage(image)
        imported.set(source.url, saved)
      } catch (error) {
        failed += 1
        process.stderr.write(`Image ${index + 1} could not be imported: ${error.message}\n`)
      } finally {
        completed += 1
        if (completed % 5 === 0 || completed === sources.length) {
          process.stdout.write(`Images processed: ${completed}/${sources.length}\n`)
        }
      }
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(concurrency, sources.length) }, () => worker()),
  )
  return { imported, failed }
}

const convertedNotes = (dailyNotes, images = new Map()) =>
  dailyNotes.map((note) => ({
    date: note.date,
    content: documentToContent(note.document, images),
    updatedAt: note.updatedAt,
  }))

const previewConflicts = (database, notes) => {
  const get = database.prepare('SELECT content FROM notes WHERE date = ?')
  let conflicts = 0
  let nonEmpty = 0
  for (const note of notes) {
    if (!note.content.trim()) continue
    nonEmpty += 1
    const existing = get.get(note.date)
    if (existing?.content.trim() && existing.content.trim() !== note.content.trim()) conflicts += 1
  }
  return { conflicts, nonEmpty }
}

const importNotes = (database, notes) => {
  const get = database.prepare('SELECT content FROM notes WHERE date = ?')
  const save = database.prepare(`
    INSERT INTO notes (date, content, updated_at)
    VALUES (?, ?, ?)
    ON CONFLICT(date) DO UPDATE SET
      content = excluded.content,
      updated_at = excluded.updated_at
  `)
  const result = { imported: 0, merged: 0, unchanged: 0, empty: 0 }

  database.exec('BEGIN IMMEDIATE')
  try {
    for (const note of notes) {
      const incoming = note.content.trim()
      if (!incoming) {
        result.empty += 1
        continue
      }

      const existing = get.get(note.date)?.content.trim() || ''
      if (existing === incoming || existing.endsWith(`\n\n${incoming}`)) {
        result.unchanged += 1
        continue
      }

      const content = existing ? `${existing}\n\n${incoming}` : incoming
      const updatedAt = existing ? new Date().toISOString() : note.updatedAt
      save.run(note.date, content, updatedAt)
      if (existing) result.merged += 1
      else result.imported += 1
    }
    database.exec('COMMIT')
  } catch (error) {
    database.exec('ROLLBACK')
    throw error
  }
  return result
}

const upgradeImageReferences = (database, images) => {
  const update = database.prepare(`
    UPDATE notes
    SET content = replace(content, ?, ?), updated_at = ?
    WHERE instr(content, ?) > 0
  `)
  let notesUpdated = 0
  const updatedAt = new Date().toISOString()

  database.exec('BEGIN IMMEDIATE')
  try {
    for (const [url, image] of images) {
      const token = `![${cleanImageAlt(image.fileName)}](noterepo:image:${image.id})`
      notesUpdated += Number(update.run(url, token, updatedAt, url).changes)
    }
    database.exec('COMMIT')
  } catch (error) {
    database.exec('ROLLBACK')
    throw error
  }
  return notesUpdated
}

const backupDatabase = async (databasePath) => {
  const checkpoint = new DatabaseSync(databasePath)
  checkpoint.exec('PRAGMA wal_checkpoint(TRUNCATE)')
  checkpoint.close()

  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')
  const backupPath = `${databasePath}.backup-reflect-${stamp}`
  await fs.copyFile(databasePath, backupPath)
  await fs.chmod(backupPath, 0o600)
  return backupPath
}

const dryRun = async (sourcePath, databasePath) => {
  const reflect = await loadReflectExport(sourcePath)
  const notes = convertedNotes(reflect.dailyNotes)
  const database = new DatabaseSync(databasePath, { readOnly: true })
  const preview = previewConflicts(database, notes)
  database.close()
  return {
    sourceNotes: reflect.totalNotes,
    dailyNotes: reflect.dailyNotes.length,
    nonEmptyDailyNotes: preview.nonEmpty,
    nonDailyNotesSkipped: reflect.nonDailyNotes,
    imageUrls: reflect.imageSources.length,
    conflictsToMerge: preview.conflicts,
    firstDate: reflect.dailyNotes[0]?.date || null,
    lastDate: reflect.dailyNotes.at(-1)?.date || null,
  }
}

const runImport = async (sourcePath, databasePath) => {
  const reflect = await loadReflectExport(sourcePath)
  const backupPath = await backupDatabase(databasePath)
  const store = await new NoteStore(databasePath).load()

  try {
    const images = await downloadImages(reflect.imageSources, store)
    const imageNotesUpdated = upgradeImageReferences(store.database, images.imported)
    const notes = convertedNotes(reflect.dailyNotes, images.imported)
    const imported = importNotes(store.database, notes)
    store.database.prepare(`
      INSERT OR REPLACE INTO metadata (key, value)
      VALUES (?, ?)
    `).run(
      `reflect_import:${reflect.checksum}`,
      JSON.stringify({
        source: path.basename(sourcePath),
        completedAt: new Date().toISOString(),
        imported,
        imagesImported: images.imported.size,
        imagesFailed: images.failed,
        imageNotesUpdated,
      }),
    )

    return {
      backupPath,
      dailyNotes: reflect.dailyNotes.length,
      nonDailyNotesSkipped: reflect.nonDailyNotes,
      ...imported,
      imagesImported: images.imported.size,
      imagesFailed: images.failed,
      imageNotesUpdated,
    }
  } finally {
    store.close()
  }
}

const parseArguments = (argumentsList) => {
  const values = new Map()
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index]
    if (argument === '--dry-run') {
      values.set('dry-run', true)
      continue
    }
    if (argument === '--source' || argument === '--database') {
      values.set(argument.slice(2), argumentsList[index + 1])
      index += 1
    }
  }
  if (!values.get('source') || !values.get('database')) {
    throw new TypeError('Pass --source and --database')
  }
  return values
}

const main = async () => {
  const argumentsMap = parseArguments(process.argv.slice(2))
  const sourcePath = path.resolve(argumentsMap.get('source'))
  const databasePath = path.resolve(argumentsMap.get('database'))
  const result = argumentsMap.get('dry-run')
    ? await dryRun(sourcePath, databasePath)
    : await runImport(sourcePath, databasePath)
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  })
}

module.exports = {
  cleanImageAlt,
  convertedNotes,
  detectImageMime,
  documentToContent,
  importNotes,
  loadReflectExport,
  previewConflicts,
  upgradeImageReferences,
  validateReflectImageUrl,
}
