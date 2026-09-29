const fs = require('node:fs/promises')
const path = require('node:path')
const { createHash } = require('node:crypto')
const { DatabaseSync } = require('node:sqlite')

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/
const IMAGE_ID_PATTERN = /^[a-f0-9]{64}$/
const IMAGE_MIME_TYPES = new Set([
  'image/gif',
  'image/jpeg',
  'image/png',
  'image/svg+xml',
  'image/webp',
])
const MAX_IMAGE_BYTES = 15_000_000

const hasNoteContent = (content) =>
  String(content)
    .split(/\r?\n/)
    .some((line) => {
      const value = line.trim()
      return value && !/^(?:-|\d+\.)$/.test(value)
    })

const isDateKey = (value) => {
  if (!DATE_PATTERN.test(value)) return false
  const [year, month, day] = value.split('-').map(Number)
  const parsed = new Date(year, month - 1, day)
  return (
    parsed.getFullYear() === year &&
    parsed.getMonth() === month - 1 &&
    parsed.getDate() === day
  )
}

const uniquePaths = (paths) =>
  [...new Set(paths.filter(Boolean).map((filePath) => path.resolve(filePath)))]

class NoteStore {
  constructor(filePath, { legacyPaths = [] } = {}) {
    this.filePath = filePath
    this.legacyPaths = uniquePaths(legacyPaths)
    this.database = null
    this.statements = null
  }

  async load() {
    await fs.mkdir(path.dirname(this.filePath), { recursive: true })
    this.database = new DatabaseSync(this.filePath)
    this.database.function('has_note_content', (content) => Number(hasNoteContent(content)))
    this.database.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;

      CREATE TABLE IF NOT EXISTS notes (
        date TEXT PRIMARY KEY,
        content TEXT NOT NULL DEFAULT '',
        updated_at TEXT
      ) STRICT;

      CREATE TABLE IF NOT EXISTS metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT;

      CREATE TABLE IF NOT EXISTS images (
        id TEXT PRIMARY KEY,
        checksum TEXT NOT NULL UNIQUE,
        mime_type TEXT NOT NULL,
        file_name TEXT NOT NULL,
        width INTEGER,
        height INTEGER,
        byte_size INTEGER NOT NULL,
        data BLOB NOT NULL,
        created_at TEXT NOT NULL
      ) STRICT;
    `)

    this.statements = {
      get: this.database.prepare(
        'SELECT content, updated_at AS updatedAt FROM notes WHERE date = ?',
      ),
      has: this.database.prepare(
        'SELECT 1 AS present FROM notes WHERE date = ? AND has_note_content(content) = 1',
      ),
      save: this.database.prepare(`
        INSERT INTO notes (date, content, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET
          content = excluded.content,
          updated_at = excluded.updated_at
      `),
      search: this.database.prepare(`
        SELECT date, content, updated_at AS updatedAt
        FROM notes
        WHERE instr(lower(content), lower(?)) > 0
        ORDER BY date DESC
        LIMIT 60
      `),
      contentNotesBefore: this.database.prepare(`
        SELECT date, content, updated_at AS updatedAt
        FROM notes
        WHERE date < ? AND has_note_content(content) = 1
        ORDER BY date DESC
        LIMIT ?
      `),
      contentNotesAfter: this.database.prepare(`
        SELECT date, content, updated_at AS updatedAt
        FROM notes
        WHERE date > ? AND has_note_content(content) = 1
        ORDER BY date ASC
        LIMIT ?
      `),
      migration: this.database.prepare(
        "SELECT value FROM metadata WHERE key = 'json_migration_v1'",
      ),
      markMigrated: this.database.prepare(`
        INSERT OR REPLACE INTO metadata (key, value)
        VALUES ('json_migration_v1', ?)
      `),
      import: this.database.prepare(`
        INSERT INTO notes (date, content, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET
          content = excluded.content,
          updated_at = excluded.updated_at
        WHERE notes.updated_at IS NULL
          OR (excluded.updated_at IS NOT NULL AND excluded.updated_at > notes.updated_at)
      `),
      saveImage: this.database.prepare(`
        INSERT OR IGNORE INTO images (
          id, checksum, mime_type, file_name, width, height, byte_size, data, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `),
      getImage: this.database.prepare(`
        SELECT
          id,
          mime_type AS mimeType,
          file_name AS fileName,
          width,
          height,
          byte_size AS byteSize,
          data,
          created_at AS createdAt
        FROM images
        WHERE id = ?
      `),
    }

    if (!this.statements.migration.get()) {
      const imported = await this.migrateLegacyNotes()
      this.statements.markMigrated.run(
        JSON.stringify({ imported, completedAt: new Date().toISOString() }),
      )
    }

    for (const databasePath of [
      this.filePath,
      `${this.filePath}-shm`,
      `${this.filePath}-wal`,
    ]) {
      try {
        await fs.chmod(databasePath, 0o600)
      } catch (error) {
        if (error.code !== 'ENOENT') throw error
      }
    }

    return this
  }

  ensureLoaded() {
    if (!this.database || !this.statements) throw new Error('Note store is not loaded')
  }

  async migrateLegacyNotes() {
    const notes = []

    for (const legacyPath of this.legacyPaths) {
      try {
        const data = JSON.parse(await fs.readFile(legacyPath, 'utf8'))
        if (!data || typeof data.notes !== 'object') continue

        for (const [date, note] of Object.entries(data.notes)) {
          if (!isDateKey(date) || !note || typeof note.content !== 'string') continue
          notes.push({
            date,
            content: note.content,
            updatedAt: typeof note.updatedAt === 'string' ? note.updatedAt : null,
          })
        }
      } catch (error) {
        if (error.code !== 'ENOENT') throw error
      }
    }

    if (!notes.length) return 0

    this.database.exec('BEGIN IMMEDIATE')
    try {
      for (const note of notes) {
        this.statements.import.run(note.date, note.content, note.updatedAt)
      }
      this.database.exec('COMMIT')
    } catch (error) {
      this.database.exec('ROLLBACK')
      throw error
    }

    return notes.length
  }

  get(date) {
    if (!isDateKey(date)) throw new TypeError('Invalid date')
    this.ensureLoaded()
    const note = this.statements.get.get(date)
    return note
      ? { content: note.content, updatedAt: note.updatedAt }
      : { content: '', updatedAt: null }
  }

  async save(date, content) {
    if (!isDateKey(date)) throw new TypeError('Invalid date')
    if (typeof content !== 'string') throw new TypeError('Content must be text')
    if (Buffer.byteLength(content, 'utf8') > 2_000_000) {
      throw new RangeError('Note is too large')
    }
    this.ensureLoaded()

    const updatedAt = new Date().toISOString()
    this.statements.save.run(date, content, updatedAt)
    return { content, updatedAt }
  }

  has(date) {
    if (!isDateKey(date)) throw new TypeError('Invalid date')
    this.ensureLoaded()
    return Boolean(this.statements.has.get(date))
  }

  search(query) {
    const normalized = query.trim()
    if (!normalized) return []
    this.ensureLoaded()
    return this.statements.search.all(normalized).map((note) => ({
      date: note.date,
      content: note.content,
      updatedAt: note.updatedAt,
    }))
  }

  contentNotesBefore(date, limit = 14) {
    if (!isDateKey(date)) throw new TypeError('Invalid date')
    if (!Number.isInteger(limit) || limit < 1) throw new TypeError('Invalid limit')
    this.ensureLoaded()
    return this.statements.contentNotesBefore.all(date, limit).reverse()
  }

  contentNotesAfter(date, limit = 14) {
    if (!isDateKey(date)) throw new TypeError('Invalid date')
    if (!Number.isInteger(limit) || limit < 1) throw new TypeError('Invalid limit')
    this.ensureLoaded()
    return this.statements.contentNotesAfter.all(date, limit)
  }

  saveImage({ data, mimeType, fileName = 'Image', width = null, height = null }) {
    this.ensureLoaded()
    if (!Buffer.isBuffer(data) || !data.length) throw new TypeError('Image is empty')
    if (data.length > MAX_IMAGE_BYTES) throw new RangeError('Image is too large')
    if (!IMAGE_MIME_TYPES.has(mimeType)) throw new TypeError('Unsupported image type')

    const normalizedName = String(fileName).replace(/[\r\n]/g, ' ').trim().slice(0, 240) || 'Image'
    const normalizedWidth = Number.isInteger(width) && width > 0 ? width : null
    const normalizedHeight = Number.isInteger(height) && height > 0 ? height : null
    const checksum = createHash('sha256').update(data).digest('hex')
    const createdAt = new Date().toISOString()

    this.statements.saveImage.run(
      checksum,
      checksum,
      mimeType,
      normalizedName,
      normalizedWidth,
      normalizedHeight,
      data.length,
      data,
      createdAt,
    )

    const image = this.getImage(checksum)
    return {
      id: image.id,
      mimeType: image.mimeType,
      fileName: image.fileName,
      width: image.width,
      height: image.height,
      byteSize: image.byteSize,
      createdAt: image.createdAt,
    }
  }

  getImage(id) {
    if (!IMAGE_ID_PATTERN.test(id)) throw new TypeError('Invalid image id')
    this.ensureLoaded()
    const image = this.statements.getImage.get(id)
    if (!image) return null
    return { ...image, data: Buffer.from(image.data) }
  }

  close() {
    if (!this.database) return
    this.database.close()
    this.database = null
    this.statements = null
  }
}

module.exports = {
  IMAGE_ID_PATTERN,
  IMAGE_MIME_TYPES,
  MAX_IMAGE_BYTES,
  NoteStore,
  hasNoteContent,
  isDateKey,
}
