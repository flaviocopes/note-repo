const MAX_PAGE_BYTES = 1_000_000
const PAGE_TIMEOUT_MS = 8_000
const PAGE_USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

const HTML_ENTITIES = {
  amp: '&',
  apos: "'",
  bull: '•',
  gt: '>',
  hellip: '…',
  laquo: '«',
  ldquo: '“',
  lsquo: '‘',
  lt: '<',
  mdash: '—',
  middot: '·',
  nbsp: ' ',
  ndash: '–',
  quot: '"',
  raquo: '»',
  rdquo: '”',
  rsquo: '’',
}

const decodeHtmlEntities = (value) =>
  value.replace(/&(?:#(\d+)|#x([\da-f]+)|([a-z]+));/gi, (entity, decimal, hex, name) => {
    if (name) return HTML_ENTITIES[name.toLowerCase()] ?? entity
    const code = Number.parseInt(decimal || hex, decimal ? 10 : 16)
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity
  })

const cleanPageText = (value) => decodeHtmlEntities(value).replace(/\s+/g, ' ').trim()

const metaTags = (html) => {
  const tags = {}
  for (const [tag] of html.matchAll(/<meta\b(?:"[^"]*"|'[^']*'|[^'">])*>/gi)) {
    const attributes = {}
    for (const match of tag.matchAll(/([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g)) {
      attributes[match[1].toLowerCase()] = match[2] ?? match[3] ?? match[4]
    }
    const key = (attributes.property || attributes.name || '').toLowerCase()
    if (key && attributes.content && !(key in tags)) tags[key] = attributes.content
  }
  return tags
}

const compactName = (value) => value.toLowerCase().replace(/[^a-z0-9]/g, '')

const withoutSiteName = (title, siteName, hostname) => {
  const match = title.match(/^(.*\S)\s+([|\-–—·•])\s+(\S.*)$/)
  if (!match) return title
  const [, rest, separator, suffix] = match
  const suffixName = compactName(suffix)
  const isSiteName =
    suffixName === compactName(siteName) ||
    hostname.split('.').slice(0, -1).includes(suffixName) ||
    (separator === '|' && suffix.split(' ').length <= 4)
  return suffixName && isSiteName ? rest : title
}

const extractPageTitle = (html, pageUrl) => {
  const meta = metaTags(html)
  const title = cleanPageText(
    meta['og:title'] ||
      meta['twitter:title'] ||
      html.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i)?.[1] ||
      '',
  )
  if (!title) return null
  const siteName = cleanPageText(meta['og:site_name'] || meta['application-name'] || '')
  return withoutSiteName(title, siteName, new URL(pageUrl).hostname).slice(0, 300)
}

const readPageHead = async (response) => {
  const chunks = []
  let size = 0
  let text = ''
  for await (const chunk of response.body) {
    const bytes = Buffer.from(chunk)
    chunks.push(bytes)
    size += bytes.length
    text += bytes.toString('latin1')
    if (size >= MAX_PAGE_BYTES || /<\/head\s*>/i.test(text.slice(-bytes.length - 8))) break
  }

  const charset =
    (response.headers.get('content-type') || '').match(/charset=["']?([\w-]+)/i)?.[1] ||
    text.match(/<meta[^>]+charset=["']?([\w-]+)/i)?.[1] ||
    'utf-8'
  let decoder
  try {
    decoder = new TextDecoder(charset)
  } catch {
    decoder = new TextDecoder()
  }
  return decoder.decode(Buffer.concat(chunks))
}

const fetchPageTitle = async (pageUrl) => {
  const response = await fetch(pageUrl, {
    headers: { Accept: 'text/html,application/xhtml+xml', 'User-Agent': PAGE_USER_AGENT },
    signal: AbortSignal.timeout(PAGE_TIMEOUT_MS),
  })
  if (!response.ok || !/html/i.test(response.headers.get('content-type') || '')) {
    await response.body?.cancel()
    return null
  }
  return extractPageTitle(await readPageHead(response), response.url || pageUrl.href)
}

const tweetDetails = (value) => {
  const match = String(value)
    .trim()
    .match(/^https?:\/\/(?:www\.)?(?:x\.com|twitter\.com)\/([a-z0-9_]+)\/status\/(\d+)(?:[/?#].*)?$/i)
  if (!match) return null
  return { url: String(value).trim(), user: match[1], id: match[2] }
}

const REDDIT_HOST = /^(?:(?:www|old|new|np|m|sh|i)\.)?reddit\.com$/i
const REDDIT_ID = /^[a-z0-9]+$/i

const redditLink = (value) => {
  let url
  try {
    url = new URL(value)
  } catch {
    return null
  }
  const parts = url.pathname.split('/').filter(Boolean)
  if (url.hostname.toLowerCase() === 'redd.it') {
    return parts.length === 1 && REDDIT_ID.test(parts[0]) ? { post: parts[0], comment: null } : null
  }
  if (!REDDIT_HOST.test(url.hostname)) return null
  if (/^(?:r|u|user)$/i.test(parts[0] || '') && parts[2] === 's' && parts[3]) return { share: true }

  const index = parts.indexOf('comments')
  const post = index === -1 ? '' : parts[index + 1] || ''
  if (!REDDIT_ID.test(post)) return null
  const comment = parts[index + 3] || ''
  return {
    subreddit: parts[0]?.toLowerCase() === 'r' && index === 2 ? parts[1] : null,
    post,
    comment: REDDIT_ID.test(comment) ? comment : null,
  }
}

const resolveRedditShare = async (value) => {
  let url = value
  for (let hop = 0; hop < 5; hop += 1) {
    const response = await fetch(url, {
      headers: { 'User-Agent': PAGE_USER_AGENT },
      redirect: 'manual',
      signal: AbortSignal.timeout(PAGE_TIMEOUT_MS),
    })
    await response.body?.cancel()
    const location = response.headers.get('location')
    if (response.status < 300 || response.status >= 400 || !location) return null
    url = new URL(location, url).href
    const link = redditLink(url)
    if (link?.post) return link
  }
  return null
}

const fetchRedditTitle = async (value) => {
  let link = redditLink(value)
  if (link?.share) link = await resolveRedditShare(value)
  if (!link?.post) return null

  const post = `https://www.reddit.com/r/${link.subreddit || 'reddit'}/comments/${link.post}/`
  const response = await fetch(`https://www.reddit.com/oembed?url=${encodeURIComponent(post)}`, {
    headers: { Accept: 'application/json', 'User-Agent': PAGE_USER_AGENT },
    signal: AbortSignal.timeout(PAGE_TIMEOUT_MS),
  })
  if (!response.ok) {
    await response.body?.cancel()
    return null
  }
  const { title } = await response.json()
  const postTitle = typeof title === 'string' ? cleanPageText(title).slice(0, 280) : ''
  if (!postTitle) return null
  return link.comment ? `Comment to ${postTitle}` : postTitle
}

const fetchLinkTitle = async (value) => {
  const url = new URL(value)
  if (!/^https?:$/.test(url.protocol)) throw new TypeError('Only web links have titles')
  const title = redditLink(url.href) ? fetchRedditTitle(url.href) : fetchPageTitle(url)
  return title.catch(() => null)
}

const linkText = (value, title) => {
  const url = value.replaceAll('(', '%28').replaceAll(')', '%29')
  const domain = new URL(url).hostname.replace(/^www\./, '')
  return `[${title.replaceAll('[', '(').replaceAll(']', ')')}](${url}) (${domain})`
}

module.exports = {
  extractPageTitle,
  fetchLinkTitle,
  linkText,
  redditLink,
  tweetDetails,
}
