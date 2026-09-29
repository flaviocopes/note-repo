const fs = require('node:fs/promises')
const http = require('node:http')
const path = require('node:path')
const {
  IMAGE_ID_PATTERN,
  IMAGE_MIME_TYPES,
  MAX_IMAGE_BYTES,
  hasNoteContent,
  isDateKey,
} = require('./store.cjs')
const { extractPageTitle, fetchLinkTitle, tweetDetails } = require('./links.cjs')
const { parseListLine } = require('./outline.cjs')

const MIME_TYPES = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2',
}

const escapeHtml = (value) =>
  String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')

const pad = (value) => String(value).padStart(2, '0')

const toDateKey = (date) =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`

const todayKey = () => toDateKey(new Date())

const fromDateKey = (value) => {
  const [year, month, day] = value.split('-').map(Number)
  return new Date(year, month - 1, day)
}

const formatDate = (date, options) => new Intl.DateTimeFormat('en', options).format(date)

const ordinal = (day) => {
  const remainder = day % 100
  if (remainder >= 11 && remainder <= 13) return `${day}th`
  if (day % 10 === 1) return `${day}st`
  if (day % 10 === 2) return `${day}nd`
  if (day % 10 === 3) return `${day}rd`
  return `${day}th`
}

const dayTitle = (date) => {
  const weekday = formatDate(date, { weekday: 'short' })
  const month = formatDate(date, { month: 'long' })
  return `${weekday}, ${month} ${ordinal(date.getDate())}, ${date.getFullYear()}`
}

const renderInline = (line) => {
  const pattern = /!\[([^\]]*)\]\(noterepo:image:([a-f0-9]{64})\)|\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>()\]]+)/gi
  let html = ''
  let cursor = 0

  for (const match of line.matchAll(pattern)) {
    html += escapeHtml(line.slice(cursor, match.index))
    const imageId = match[2]
    if (imageId) {
      const alt = match[1] || 'Image'
      html += `<img class="note-image" src="/api/images/${imageId}" data-image-id="${imageId}" alt="${escapeHtml(alt)}" draggable="false">`
      cursor = match.index + match[0].length
      continue
    }

    const markdownUrl = match[4]
    const rawUrl = markdownUrl || match[5]
    const url = markdownUrl ? rawUrl : rawUrl.replace(/[.,;!?]+$/, '')
    const suffix = rawUrl.slice(url.length)
    const label = match[3] || url
    html += `<a href="${escapeHtml(url)}" data-url="${escapeHtml(url)}">${escapeHtml(label)}</a>${escapeHtml(suffix)}`
    cursor = match.index + match[0].length
  }

  return html + escapeHtml(line.slice(cursor))
}

const renderTweetPreview = ({ url, user, id }) => {
  const safeUrl = escapeHtml(url)
  const safeUser = escapeHtml(user)
  return `<div class="tweet-preview" data-tweet-url="${safeUrl}" data-tweet-id="${id}" data-tweet-user="${safeUser}" contenteditable="false">
    <div class="tweet-preview-fallback">
      <span class="tweet-preview-mark" aria-hidden="true">X</span>
      <span class="tweet-preview-summary"><strong>@${safeUser}</strong><span>Loading post preview…</span></span>
    </div>
    <div class="tweet-preview-embed" aria-hidden="true"></div>
    <a class="tweet-preview-link" href="${safeUrl}" data-url="${safeUrl}" aria-label="Open post by @${safeUser} on X"></a>
  </div>`
}

const renderListItem = (body, children) => {
  const tweet = tweetDetails(body)
  const imageOnly = /^!\[[^\]]*\]\(noterepo:image:[a-f0-9]{64}\)$/i.test(body.trim())
  const attributes = tweet
    ? ' class="note-tweet-item"'
    : imageOnly
      ? ' class="note-image-item" data-image-item="true" draggable="true" title="Click to select. Drag to move."'
      : ''
  const content = tweet ? renderTweetPreview(tweet) : renderInline(body)
  return `<li${attributes}>${content || '<br>'}${children}</li>`
}

const renderLists = (entries, start, depth) => {
  const parts = []
  let index = start

  while (index < entries.length && entries[index].depth === depth) {
    const { ordered, start: listStart } = entries[index]
    const items = []

    while (index < entries.length && entries[index].depth === depth && entries[index].ordered === ordered) {
      const entry = entries[index]
      index += 1
      let children = ''
      if (index < entries.length && entries[index].depth > depth) {
        const nested = renderLists(entries, index, depth + 1)
        children = nested.html
        index = nested.next
      }
      items.push(renderListItem(entry.body, children))
    }

    parts.push(
      ordered
        ? `<ol${listStart === 1 ? '' : ` start="${listStart}"`}>${items.join('')}</ol>`
        : `<ul>${items.join('')}</ul>`,
    )
  }

  return { html: parts.join(''), next: index }
}

const renderNoteHtml = (content) => {
  if (!String(content).trim()) return '<ul><li><br></li></ul>'
  const entries = []
  for (const line of String(content).split('\n')) {
    const previousDepth = entries.length ? entries[entries.length - 1].depth : -1
    entries.push(parseListLine(line, previousDepth))
  }
  return renderLists(entries, 0, 0).html
}

const daySection = (dateKey, note) => {
  const date = fromDateKey(dateKey)
  const title = dayTitle(date)

  return `
    <article
      class="day-note${dateKey === todayKey() ? ' is-today' : ''}"
      data-note-date="${dateKey}"
      data-base="${escapeHtml(note.content)}"
      x-data="noteEditor('${dateKey}')"
      x-init="mount()"
    >
      <header class="day-note-header">
        <h2>${escapeHtml(title)}</h2>
      </header>
      <div
        class="note-editor-body"
        :class="{ 'is-image-drop-target': imageDragActive, 'is-image-uploading': uploadingImages > 0 }"
        x-ref="editor"
        contenteditable="true"
        role="textbox"
        aria-multiline="true"
        @focus="focusDay()"
        @input="contentChanged()"
        @paste="handlePaste($event)"
        @dragenter="imageDragEntered($event)"
        @dragover="imageDragOver($event)"
        @dragleave="imageDragLeft($event)"
        @drop="dropImages($event)"
        @dragstart="startImageItemDrag($event)"
        @dragend="finishImageItemDrag()"
        @blur="save()"
        @keydown="editorShortcut($event)"
        @click="openEditorLink($event)"
        aria-label="Daily note for ${dateKey}"
        spellcheck="true"
      >${renderNoteHtml(note.content)}</div>
    </article>`
}

const sentinel = (direction, boundary) => `
    <div
      class="feed-sentinel"
      data-direction="${direction}"
      hx-get="/api/feed?${direction}=${boundary}"
      hx-trigger="intersect once"
      hx-swap="outerHTML"
    ></div>`

const sectionsFromNotes = (notes) =>
  notes.map(({ date, content, updatedAt }) => daySection(date, { content, updatedAt })).join('')

const feedBefore = (store, boundary, count = 14) => {
  const notes = store.contentNotesBefore(boundary, count)
  if (!notes.length) return ''
  return `${sentinel('before', notes[0].date)}${sectionsFromNotes(notes)}`
}

const feedAfter = (store, boundary, count = 14) => {
  const today = todayKey()
  const notes = store.contentNotesAfter(boundary, count).filter((note) => note.date < today)
  const end = notes.length < count ? daySection(today, store.get(today)) : sentinel('after', notes.at(-1).date)
  return `${sectionsFromNotes(notes)}${end}`
}

const feedInitial = (store, anchor) => {
  const today = todayKey()
  const date = anchor < today ? anchor : today
  const earlier = feedBefore(store, date, 7)
  if (date === today) return `${earlier}${daySection(today, store.get(today))}`
  const current = store.has(date) ? sectionsFromNotes([{ date, ...store.get(date) }]) : ''
  return `${earlier}${current}${feedAfter(store, date, 7)}`
}

const searchResults = (store, query) => {
  if (!query.trim()) return ''
  const results = store.search(query)
  if (!results.length) return '<p class="search-empty">No matches</p>'

  return results
    .map(({ date, content }) => {
      const label = formatDate(fromDateKey(date), {
        weekday: 'short',
        month: 'short',
        day: 'numeric',
        year: 'numeric',
      })
      const excerpt = content
        .replace(/!\[[^\]]*\]\(noterepo:image:[a-f0-9]{64}\)/gi, '[Image]')
        .replace(/\s+/g, ' ')
        .trim()
        .slice(0, 120)
      return `
        <button class="search-result" type="button" @click="jumpToNote('${date}')">
          <strong>${escapeHtml(label)}</strong>
          <span>${escapeHtml(excerpt)}</span>
        </button>`
    })
    .join('')
}

const readBody = async (request) => {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > 2_100_000) throw new RangeError('Request is too large')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString('utf8')
}

const readImageBody = async (request) => {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > MAX_IMAGE_BYTES) throw new RangeError('Image is too large')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks)
}

const hasImageSignature = (data, mimeType) => {
  if (mimeType === 'image/png') {
    return data.length >= 8 && data.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))
  }
  if (mimeType === 'image/jpeg') {
    return data.length >= 3 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff
  }
  if (mimeType === 'image/gif') {
    const signature = data.subarray(0, 6).toString('ascii')
    return signature === 'GIF87a' || signature === 'GIF89a'
  }
  if (mimeType === 'image/webp') {
    return (
      data.length >= 12 &&
      data.subarray(0, 4).toString('ascii') === 'RIFF' &&
      data.subarray(8, 12).toString('ascii') === 'WEBP'
    )
  }
  if (mimeType === 'image/svg+xml') {
    const source = data.toString('utf8').trim()
    const isSvg = /^(?:<\?xml[^>]*>\s*)?<svg\b/i.test(source)
    const unsafe = /<!doctype|<script|<foreignObject|<(?:iframe|object|embed)\b|\bon\w+\s*=|(?:href|xlink:href)\s*=\s*["']\s*(?:https?:|\/\/|data:)|url\s*\(\s*["']?\s*(?:https?:|\/\/|data:)/i.test(source)
    return isSvg && !unsafe
  }
  return false
}

const imageFileName = (value) => {
  if (typeof value !== 'string') return 'Image'
  try {
    return decodeURIComponent(value).replace(/[\r\n]/g, ' ').trim().slice(0, 240) || 'Image'
  } catch {
    return 'Image'
  }
}

const imageDimension = (value) => {
  const dimension = Number(value)
  return Number.isInteger(dimension) && dimension > 0 && dimension <= 100_000
    ? dimension
    : null
}

const send = (response, status, body = '', contentType = 'text/plain; charset=utf-8') => {
  response.writeHead(status, {
    'Content-Type': contentType,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://platform.twitter.com; connect-src 'self'; img-src 'self' data:; frame-src https://platform.twitter.com https://syndication.twitter.com; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
  })
  response.end(body)
}

const sendImage = (response, image) => {
  response.writeHead(200, {
    'Content-Type': image.mimeType,
    'Content-Length': image.byteSize,
    'Cache-Control': 'private, max-age=31536000, immutable',
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'",
  })
  response.end(image.data)
}

const serveStatic = async (response, distDir, pathname) => {
  const requested = pathname === '/' ? 'index.html' : pathname.slice(1)
  const filePath = path.resolve(distDir, requested)
  const relative = path.relative(distDir, filePath)
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    send(response, 403, 'Forbidden')
    return
  }

  try {
    const content = await fs.readFile(filePath)
    const type = MIME_TYPES[path.extname(filePath)] || 'application/octet-stream'
    send(response, 200, content, type)
  } catch (error) {
    send(response, error.code === 'ENOENT' ? 404 : 500, 'Not found')
  }
}

const createAppServer = ({ distDir, store }) => {
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1')

    try {
      if (request.method === 'GET' && url.pathname === '/api/feed') {
        const before = url.searchParams.get('before')
        const after = url.searchParams.get('after')
        const requestedAnchor = url.searchParams.get('anchor') || 'today'
        const anchor = requestedAnchor === 'today' ? todayKey() : requestedAnchor

        if (before) {
          if (!isDateKey(before)) throw new TypeError('Invalid date')
          send(response, 200, feedBefore(store, before), 'text/html; charset=utf-8')
          return
        }
        if (after) {
          if (!isDateKey(after)) throw new TypeError('Invalid date')
          send(response, 200, feedAfter(store, after), 'text/html; charset=utf-8')
          return
        }
        if (!isDateKey(anchor)) throw new TypeError('Invalid date')
        send(response, 200, feedInitial(store, anchor), 'text/html; charset=utf-8')
        return
      }

      if (request.method === 'GET' && url.pathname === '/api/search') {
        send(response, 200, searchResults(store, url.searchParams.get('q') || ''), 'text/html; charset=utf-8')
        return
      }

      if (request.method === 'GET' && url.pathname === '/api/link-title') {
        const title = await fetchLinkTitle(url.searchParams.get('url') || '')
        send(response, 200, JSON.stringify({ title }), 'application/json; charset=utf-8')
        return
      }

      if (request.method === 'POST' && url.pathname === '/api/images') {
        const mimeType = String(request.headers['content-type'] || '')
          .split(';', 1)[0]
          .trim()
          .toLowerCase()
        if (!IMAGE_MIME_TYPES.has(mimeType)) throw new TypeError('Unsupported image type')

        const data = await readImageBody(request)
        if (!data.length) throw new TypeError('Image is empty')
        if (!hasImageSignature(data, mimeType)) throw new TypeError('Image data does not match its type')

        const image = store.saveImage({
          data,
          mimeType,
          fileName: imageFileName(request.headers['x-image-name']),
          width: imageDimension(request.headers['x-image-width']),
          height: imageDimension(request.headers['x-image-height']),
        })
        send(
          response,
          201,
          JSON.stringify({
            id: image.id,
            src: `/api/images/${image.id}`,
            alt: image.fileName,
            width: image.width,
            height: image.height,
          }),
          'application/json; charset=utf-8',
        )
        return
      }

      const imageMatch = url.pathname.match(/^\/api\/images\/([a-f0-9]{64})$/)
      if (request.method === 'GET' && imageMatch) {
        const id = imageMatch[1]
        if (!IMAGE_ID_PATTERN.test(id)) throw new TypeError('Invalid image id')
        const image = store.getImage(id)
        if (!image) {
          send(response, 404, 'Image not found')
          return
        }
        sendImage(response, image)
        return
      }

      const noteMatch = url.pathname.match(/^\/api\/day\/(\d{4}-\d{2}-\d{2})$/)
      if (noteMatch) {
        const date = noteMatch[1]
        if (!isDateKey(date)) throw new TypeError('Invalid date')

        if (request.method === 'GET' && url.searchParams.get('format') === 'json') {
          const { content } = store.get(date)
          const note = { content, hasContent: hasNoteContent(content), html: renderNoteHtml(content) }
          send(response, 200, JSON.stringify(note), 'application/json; charset=utf-8')
          return
        }

        if (request.method === 'GET') {
          send(response, 200, daySection(date, store.get(date)), 'text/html; charset=utf-8')
          return
        }

        if (request.method === 'PUT') {
          const payload = JSON.parse(await readBody(request))
          const saved = await store.save(date, payload.content, { base: payload.base })
          const merged = saved.content !== payload.content
          send(
            response,
            200,
            JSON.stringify({
              updatedAt: saved.updatedAt,
              content: saved.content,
              ...(merged && { html: renderNoteHtml(saved.content) }),
            }),
            'application/json; charset=utf-8',
          )
          return
        }
      }

      if (request.method === 'GET') {
        await serveStatic(response, distDir, url.pathname)
        return
      }

      send(response, 404, 'Not found')
    } catch (error) {
      const status =
        error instanceof RangeError ? 413 : error instanceof SyntaxError || error instanceof TypeError ? 400 : 500
      send(response, status, status === 500 ? 'Something went wrong' : error.message)
    }
  })

  return {
    listen() {
      return new Promise((resolve, reject) => {
        server.once('error', reject)
        server.listen(0, '127.0.0.1', () => {
          const address = server.address()
          resolve(`http://127.0.0.1:${address.port}`)
        })
      })
    },
    close() {
      return new Promise((resolve) => server.close(resolve))
    },
  }
}

module.exports = {
  createAppServer,
  daySection,
  escapeHtml,
  extractPageTitle,
  feedAfter,
  feedBefore,
  feedInitial,
  dayTitle,
  renderNoteHtml,
  searchResults,
  hasImageSignature,
  todayKey,
}
