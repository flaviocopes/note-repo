const { tweetDetails } = require('./links.cjs')

const IMAGE_ITEM = /^!\[([^\]]*)\]\(noterepo:image:([a-f0-9]{64})\)$/i
const INLINE_LINK = /\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)|(https?:\/\/[^\s<>()\]]+)/gi
const MAX_MERGE_CELLS = 4_000_000

const parseListLine = (line, previousDepth) => {
  const indent = line.match(/^[ \t]*/)[0]
  const spaces = indent.replace(/\t/g, '').length
  const tabs = indent.length - spaces
  const depth = Math.min(tabs + Math.floor(spaces / 2), previousDepth + 1)
  const rest = line.slice(indent.length)

  const ordered = rest.match(/^(\d+)\.(?:\s+(.*))?$/)
  if (ordered) return { depth, ordered: true, start: Number(ordered[1]), body: ordered[2] || '' }

  const bullet = rest.match(/^-\s?(.*)$/)
  return { depth, ordered: false, start: 1, body: bullet ? bullet[1] : rest }
}

const parseOutline = (content) => {
  const entries = []
  for (const raw of String(content).split('\n')) {
    const previousDepth = entries.length ? entries.at(-1).depth : -1
    entries.push({ ...parseListLine(raw, previousDepth), raw, dirty: false })
  }
  return entries.length === 1 && !entries[0].raw ? [] : entries
}

const formatEntry = ({ depth, ordered, start, body }) => {
  const indent = '  '.repeat(depth)
  const marker = ordered ? `${start}.` : '-'
  if (body.trim()) return `${indent}${marker} ${body}`.trimEnd()
  return depth ? `${indent}${marker}` : ''
}

const renumber = (entries) => {
  const next = []
  for (const entry of entries) {
    next.length = entry.depth + 1
    if (!entry.ordered) {
      next[entry.depth] = null
      continue
    }
    const expected = next[entry.depth]
    if (expected && entry.start !== expected) {
      entry.start = expected
      entry.dirty = true
    }
    next[entry.depth] = entry.start + 1
  }
  return entries
}

const serializeOutline = (entries) =>
  renumber(entries)
    .map((entry) => (entry.dirty ? formatEntry(entry) : entry.raw))
    .join('\n')

const isItem = (entry) => Boolean(entry.body.trim())

const subtreeEnd = (entries, index) => {
  let end = index + 1
  while (end < entries.length && entries[end].depth > entries[index].depth) end += 1
  return end
}

const itemLinks = (text) =>
  [...text.matchAll(INLINE_LINK)].map((match) => ({
    title: match[1] || null,
    url: match[2] || match[3].replace(/[.,;!?]+$/, ''),
  }))

const describeItem = (entry, n) => {
  const text = entry.body.trim()
  const item = {
    n,
    level: entry.depth,
    list: entry.ordered ? 'numbered' : 'bullet',
    ...(entry.ordered && { number: entry.start }),
    kind: 'text',
    text,
  }

  const image = text.match(IMAGE_ITEM)
  if (image) return { ...item, kind: 'image', image: { id: image[2].toLowerCase(), alt: image[1] } }

  const post = tweetDetails(text)
  if (post) return { ...item, kind: 'post', post }

  const links = itemLinks(text)
  return links.length ? { ...item, kind: 'link', links } : item
}

const describeOutline = (entries) => {
  let n = 0
  return renumber(entries).flatMap((entry) => (isItem(entry) ? [describeItem(entry, (n += 1))] : []))
}

const cleanText = (value) =>
  String(value)
    .replace(/\r\n?/g, '\n')
    .replace(/[\u200b\ufeff]/g, '')
    .replace(/[^\S\n]+$/gm, '')

const parseInputLine = (line) => {
  const indent = line.match(/^[ \t]*/)[0]
  const spaces = indent.replace(/\t/g, '').length
  const level = indent.length - spaces + Math.floor(spaces / 2)
  const rest = line.slice(indent.length)
  const ordered = rest.match(/^(\d+)[.)](?:\s+|$)(.*)$/)
  if (ordered) return { level, ordered: true, body: ordered[2].trim() }
  const bullet = rest.match(/^[-*+](?:\s+|$)(.*)$/)
  return { level, ordered: false, body: (bullet ? bullet[1] : rest).trim() }
}

const inputEntries = (text) => {
  const entries = []
  for (const line of cleanText(text).split('\n')) {
    const { level, ordered, body } = parseInputLine(line)
    if (body) entries.push({ depth: level, ordered, start: 1, body, raw: '', dirty: true })
  }
  return entries
}

const matchLines = (a, b) => {
  const width = b.length + 1
  const table = new Uint32Array((a.length + 1) * width)
  for (let i = a.length - 1; i >= 0; i -= 1) {
    for (let j = b.length - 1; j >= 0; j -= 1) {
      table[i * width + j] =
        a[i] === b[j]
          ? table[(i + 1) * width + j + 1] + 1
          : Math.max(table[(i + 1) * width + j], table[i * width + j + 1])
    }
  }
  const pairs = []
  let i = 0
  let j = 0
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) {
      pairs.push([i, j])
      i += 1
      j += 1
    } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) {
      i += 1
    } else {
      j += 1
    }
  }
  return pairs
}

const mergeContent = (base, mine, theirs) => {
  if (mine === base || mine === theirs) return theirs
  if (theirs === base) return mine

  const baseLines = base.split('\n')
  const mineLines = mine.split('\n')
  const theirLines = theirs.split('\n')
  if (
    (baseLines.length + 1) * (mineLines.length + 1) > MAX_MERGE_CELLS ||
    (baseLines.length + 1) * (theirLines.length + 1) > MAX_MERGE_CELLS
  ) {
    const added = theirLines.filter((line) => line && !baseLines.includes(line) && !mineLines.includes(line))
    return [...mineLines, ...added].join('\n')
  }

  const inMine = new Map(matchLines(baseLines, mineLines))
  const mineIndexFrom = (baseIndex) => {
    for (let index = baseIndex; index < baseLines.length; index += 1) {
      if (inMine.has(index)) return inMine.get(index)
    }
    return mineLines.length
  }

  const removed = new Set()
  const inserted = new Map()
  let baseIndex = 0
  let theirIndex = 0
  for (const [nextBase, nextTheirs] of [...matchLines(baseLines, theirLines), [baseLines.length, theirLines.length]]) {
    const deleted = []
    for (let index = baseIndex; index < nextBase; index += 1) deleted.push(index)
    let added = theirLines.slice(theirIndex, nextTheirs)

    if (deleted.length || added.length) {
      const untouched = deleted.every((index) => inMine.has(index))
      if (untouched) deleted.forEach((index) => removed.add(inMine.get(index)))
      else added = added.filter((line) => !mineLines.includes(line))
      const position = mineIndexFrom(nextBase)
      inserted.set(position, [...(inserted.get(position) || []), ...added])
    }
    baseIndex = nextBase + 1
    theirIndex = nextTheirs + 1
  }

  const merged = []
  mineLines.forEach((line, index) => {
    merged.push(...(inserted.get(index) || []))
    if (!removed.has(index)) merged.push(line)
  })
  merged.push(...(inserted.get(mineLines.length) || []))
  return merged.join('\n')
}

module.exports = {
  cleanText,
  describeOutline,
  formatEntry,
  inputEntries,
  mergeContent,
  parseListLine,
  parseOutline,
  renumber,
  serializeOutline,
  subtreeEnd,
}
