import Alpine from 'alpinejs'
import htmx from 'htmx.org'

type UploadedImage = {
  id: string
  src: string
  alt: string
  width: number | null
  height: number | null
}

type TweetDetails = {
  url: string
  user: string
  id: string
}

type StoredNote = {
  content: string
  hasContent: boolean
  html: string
}

type CaretPosition = {
  item: number
  offset: number
}

const IMAGE_TYPES = new Set([
  'image/gif',
  'image/jpeg',
  'image/png',
  'image/svg+xml',
  'image/webp',
])
const MAX_IMAGE_BYTES = 15_000_000
const IMAGE_ITEM_MIME = 'application/x-noterepo-image-item'
const X_WIDGET_SCRIPT = 'https://platform.twitter.com/widgets.js'

let draggedImageItem: HTMLLIElement | null = null
let selectedImageItem: HTMLLIElement | null = null
let tweetWidgetsPromise: Promise<NonNullable<Window['twttr']>> | null = null
let outsideChanges = Promise.resolve()

const lightScheme = window.matchMedia('(prefers-color-scheme: light)')
const tweetTheme = () => (lightScheme.matches ? 'light' : 'dark')

type ImageInsertionPoint = {
  reference: HTMLLIElement | null
  before: boolean
}

const pad = (value: number) => String(value).padStart(2, '0')

const toDateKey = (date: Date) =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`

const fromDateKey = (value: string) => {
  const [year, month, day] = value.split('-').map(Number)
  return new Date(year, month - 1, day)
}

const todayKey = () => toDateKey(new Date())

const escapeHtml = (value: string) =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')

const linkifyHtml = (value: string) => {
  const pattern = /https?:\/\/[^\s<>()\]]+/gi
  let html = ''
  let cursor = 0
  for (const match of value.matchAll(pattern)) {
    html += escapeHtml(value.slice(cursor, match.index))
    const rawUrl = match[0]
    const url = rawUrl.replace(/[.,;!?]+$/, '')
    const suffix = rawUrl.slice(url.length)
    html += `<a href="${escapeHtml(url)}" data-url="${escapeHtml(url)}">${escapeHtml(url)}</a>${escapeHtml(suffix)}`
    cursor = match.index + rawUrl.length
  }
  return html + escapeHtml(value.slice(cursor))
}

const cleanPastedText = (value: string) =>
  value
    .replace(/\r\n?/g, '\n')
    .replace(/[\u200b\ufeff]/g, '')
    .replace(/[^\S\n]+$/gm, '')
    .trim()

const createLink = (value: string) => {
  const url = value.replaceAll('(', '%28').replaceAll(')', '%29')
  const link = document.createElement('a')
  link.href = url
  link.dataset.url = url
  link.textContent = url
  return link
}

const fetchLinkTitle = async (url: string) => {
  try {
    const response = await fetch(`/api/link-title?url=${encodeURIComponent(url)}`)
    if (!response.ok) return null
    const { title } = (await response.json()) as { title: string | null }
    return title
  } catch {
    return null
  }
}

const showLinkTitle = (link: HTMLAnchorElement, title: string) => {
  const selection = window.getSelection()
  const range = selection?.rangeCount ? selection.getRangeAt(0) : null
  const caretAtLink = Boolean(
    range?.collapsed &&
    (link.contains(range.startContainer) ||
      (range.startContainer === link.parentNode &&
        range.startContainer.childNodes[range.startOffset - 1] === link)),
  )

  const domain = new URL(link.href).hostname.replace(/^www\./, '')
  const domainText = document.createTextNode(` (${domain})`)
  link.textContent = title.replaceAll('[', '(').replaceAll(']', ')')
  link.after(domainText)

  if (!caretAtLink) return
  const caret = document.createRange()
  caret.setStartAfter(domainText)
  caret.collapse(true)
  selection?.removeAllRanges()
  selection?.addRange(caret)
}

const tweetDetails = (value: string): TweetDetails | null => {
  const url = value.trim()
  const match = url.match(
    /^https?:\/\/(?:www\.)?(?:x\.com|twitter\.com)\/([a-z0-9_]+)\/status\/(\d+)(?:[/?#].*)?$/i,
  )
  return match ? { url, user: match[1], id: match[2] } : null
}

const createTweetPreview = ({ url, user, id }: TweetDetails) => {
  const preview = document.createElement('div')
  preview.className = 'tweet-preview'
  preview.dataset.tweetUrl = url
  preview.dataset.tweetId = id
  preview.dataset.tweetUser = user
  preview.contentEditable = 'false'

  const fallback = document.createElement('div')
  fallback.className = 'tweet-preview-fallback'

  const mark = document.createElement('span')
  mark.className = 'tweet-preview-mark'
  mark.setAttribute('aria-hidden', 'true')
  mark.textContent = 'X'

  const summary = document.createElement('span')
  summary.className = 'tweet-preview-summary'
  const author = document.createElement('strong')
  author.textContent = `@${user}`
  const status = document.createElement('span')
  status.textContent = 'Loading post preview…'
  summary.append(author, status)
  fallback.append(mark, summary)

  const embed = document.createElement('div')
  embed.className = 'tweet-preview-embed'
  embed.setAttribute('aria-hidden', 'true')

  const link = document.createElement('a')
  link.className = 'tweet-preview-link'
  link.href = url
  link.dataset.url = url
  link.setAttribute('aria-label', `Open post by @${user} on X`)

  preview.append(fallback, embed, link)
  return preview
}

const loadTweetWidgets = () => {
  if (window.twttr?.widgets?.createTweet) return Promise.resolve(window.twttr)
  if (tweetWidgetsPromise) return tweetWidgetsPromise

  tweetWidgetsPromise = new Promise((resolve, reject) => {
    const startedAt = Date.now()
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${X_WIDGET_SCRIPT}"]`)
    const script = existing || document.createElement('script')
    let timer = 0

    const finish = () => {
      window.clearInterval(timer)
      if (window.twttr?.widgets?.createTweet) resolve(window.twttr)
      else reject(new Error('X post previews did not load'))
    }

    const poll = () => {
      if (window.twttr?.widgets?.createTweet || Date.now() - startedAt >= 8_000) finish()
    }

    script.addEventListener('error', finish, { once: true })
    if (!existing) {
      script.src = X_WIDGET_SCRIPT
      script.async = true
      script.setAttribute('charset', 'utf-8')
      document.head.append(script)
    }
    timer = window.setInterval(poll, 50)
    poll()
  })

  return tweetWidgetsPromise
}

const isTextBlock = (node: Node | undefined): node is HTMLElement =>
  node instanceof HTMLElement &&
  /^(UL|OL|LI|DIV|P)$/.test(node.tagName) &&
  !node.matches('.note-image-item, .note-tweet-item')

const visibleCaretPosition = (range: Range) => {
  let node = range.startContainer
  let offset = range.startOffset
  let position = { node, offset }
  for (;;) {
    const before = node.childNodes[offset - 1]
    const after = node.childNodes[offset]
    if (isTextBlock(before)) {
      node = before
      offset = before.childNodes.length
    } else if (!before && isTextBlock(after)) {
      node = after
      offset = 0
    } else {
      break
    }
    if (!/^(UL|OL)$/.test(node.nodeName)) position = { node, offset }
  }
  const { childNodes } = position.node
  if (position.offset === childNodes.length && childNodes[position.offset - 1]?.nodeName === 'BR') {
    position.offset -= 1
  }
  return position
}

const insertAtSelection = (node: Node) => {
  const selection = window.getSelection()
  if (!selection?.rangeCount) return
  const range = selection.getRangeAt(0)
  range.deleteContents()
  const caret = visibleCaretPosition(range)
  range.setStart(caret.node, caret.offset)
  range.collapse(true)
  const lastNode = node instanceof DocumentFragment ? node.lastChild : node
  range.insertNode(node)
  if (!lastNode) return
  range.setStartAfter(lastNode)
  range.collapse(true)
  selection.removeAllRanges()
  selection.addRange(range)
}

const cleanImageAlt = (value: string) =>
  value.replace(/[\[\]\r\n]/g, ' ').trim().slice(0, 240) || 'Image'

const editorRange = (editor: HTMLElement) => {
  const selection = window.getSelection()
  if (selection?.rangeCount) {
    const range = selection.getRangeAt(0)
    if (editor.contains(range.commonAncestorContainer)) return range.cloneRange()
  }

  const range = document.createRange()
  range.selectNodeContents(editor)
  range.collapse(false)
  return range
}

const createImageItem = (image: UploadedImage) => {
  const element = document.createElement('img')
  element.className = 'note-image'
  element.src = image.src
  element.dataset.imageId = image.id
  element.alt = cleanImageAlt(image.alt)
  element.draggable = false
  if (image.width) element.dataset.width = String(image.width)
  if (image.height) element.dataset.height = String(image.height)

  const item = document.createElement('li')
  item.className = 'note-image-item'
  item.dataset.imageItem = 'true'
  item.draggable = true
  item.title = 'Click to select. Drag to move.'
  item.append(element)
  return item
}

const closestListItem = (editor: HTMLElement, node: Node | null) => {
  const element = node instanceof HTMLElement ? node : node?.parentElement || null
  const item = element?.closest<HTMLLIElement>('li') || null
  return item && editor.contains(item) ? item : null
}

const caretListItem = (editor: HTMLElement) => {
  if (selectedImageItem && editor.contains(selectedImageItem)) return selectedImageItem
  const selection = window.getSelection()
  if (!selection?.rangeCount) return null
  const range = selection.getRangeAt(0)
  let node: Node | null = range.startContainer
  if (node instanceof HTMLElement && /^(UL|OL)$/.test(node.tagName)) {
    node = node.childNodes[range.startOffset] || node.lastChild
  }
  return closestListItem(editor, node)
}

const nestedListIn = (item: HTMLLIElement, tagName: string) => {
  const last = item.lastElementChild
  if (last && last.tagName === tagName) return last
  const list = document.createElement(tagName)
  item.append(list)
  return list
}

const indentListItem = (item: HTMLLIElement) => {
  const list = item.parentElement
  const previous = item.previousElementSibling
  if (!list || !(previous instanceof HTMLLIElement)) return false
  nestedListIn(previous, list.tagName).append(item)
  return true
}

const outdentListItem = (item: HTMLLIElement) => {
  const list = item.parentElement
  const parentItem = list?.parentElement
  const outerList = parentItem?.parentElement
  if (!list || !(parentItem instanceof HTMLLIElement) || !outerList) return false

  const following: Element[] = []
  for (let sibling = item.nextElementSibling; sibling; sibling = sibling.nextElementSibling) {
    following.push(sibling)
  }
  if (following.length) nestedListIn(item, list.tagName).append(...following)

  outerList.insertBefore(item, parentItem.nextSibling)
  if (!list.children.length) list.remove()
  return true
}

const moveListItem = (editor: HTMLElement, outdent: boolean) => {
  const item = caretListItem(editor)
  if (!item) return false

  const selection = window.getSelection()
  const range = selection?.rangeCount ? selection.getRangeAt(0) : null
  const caret = range ? { node: range.startContainer, offset: range.startOffset } : null

  const moved = outdent ? outdentListItem(item) : indentListItem(item)
  if (!moved) return false

  const restored = document.createRange()
  if (item === selectedImageItem) {
    restored.selectNode(item)
  } else {
    if (caret && item.contains(caret.node)) restored.setStart(caret.node, caret.offset)
    else restored.setStart(item, 0)
    restored.collapse(true)
  }
  selection?.removeAllRanges()
  selection?.addRange(restored)
  return true
}

const insertionAtRange = (editor: HTMLElement, range: Range): ImageInsertionPoint => {
  if (!editor.contains(range.commonAncestorContainer)) range = editorRange(editor)
  return {
    reference: closestListItem(editor, range.commonAncestorContainer),
    before: false,
  }
}

const insertionAtDrop = (editor: HTMLElement, event: DragEvent): ImageInsertionPoint => {
  const reference = closestListItem(editor, event.target as Node)
  if (!reference) return { reference: null, before: false }
  const bounds = reference.getBoundingClientRect()
  return { reference, before: event.clientY < bounds.top + bounds.height / 2 }
}

const isEmptyListItem = (item: HTMLLIElement) =>
  !item.querySelector('img') && !(item.textContent || '').trim()

const appendBulletItem = (
  editor: HTMLElement,
  item: HTMLLIElement,
  insertion: ImageInsertionPoint,
) => {
  const reference = insertion.reference
  const list = reference?.parentElement

  if (reference && list?.tagName === 'UL') {
    if (isEmptyListItem(reference)) reference.replaceWith(item)
    else list.insertBefore(item, insertion.before ? reference : reference.nextSibling)
    return
  }

  const bulletList = document.createElement('ul')
  bulletList.append(item)
  if (reference && list) {
    list.insertAdjacentElement(insertion.before ? 'beforebegin' : 'afterend', bulletList)
    return
  }

  editor.append(bulletList)
}

const clearDropPosition = () => {
  document
    .querySelectorAll('.note-image-drop-before, .note-image-drop-after')
    .forEach((item) => item.classList.remove('note-image-drop-before', 'note-image-drop-after'))
}

const showDropPosition = (insertion: ImageInsertionPoint) => {
  clearDropPosition()
  insertion.reference?.classList.add(
    insertion.before ? 'note-image-drop-before' : 'note-image-drop-after',
  )
}

const clearSelectedImage = () => {
  selectedImageItem?.classList.remove('is-selected')
  selectedImageItem?.removeAttribute('data-selected')
  selectedImageItem = null
}

const selectImage = (editor: HTMLElement, item: HTMLLIElement) => {
  clearSelectedImage()
  selectedImageItem = item
  item.classList.add('is-selected')
  item.dataset.selected = 'true'
  editor.focus({ preventScroll: true })

  const range = document.createRange()
  range.selectNode(item)
  const selection = window.getSelection()
  selection?.removeAllRanges()
  selection?.addRange(range)
}

const ensureEditorHasItem = (editor: HTMLElement) => {
  if (editor.querySelector('li')) return
  const list = document.createElement('ul')
  const item = document.createElement('li')
  item.append(document.createElement('br'))
  list.append(item)
  editor.append(list)
}

const dispatchEditorInput = (editor: HTMLElement) => {
  editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertFromDrop' }))
}

const insertImageItem = (
  editor: HTMLElement,
  insertion: ImageInsertionPoint,
  image: UploadedImage,
) => {
  const item = createImageItem(image)
  appendBulletItem(editor, item, insertion)

  const range = document.createRange()
  range.selectNode(item)
  range.collapse(false)
  const selection = window.getSelection()
  selection?.removeAllRanges()
  selection?.addRange(range)
  return { reference: item, before: false }
}

const imageDimensions = async (file: File) => {
  try {
    const bitmap = await createImageBitmap(file)
    const dimensions = { width: bitmap.width, height: bitmap.height }
    bitmap.close()
    return dimensions
  } catch {
    return { width: null, height: null }
  }
}

const uploadImage = async (file: File): Promise<UploadedImage> => {
  if (!IMAGE_TYPES.has(file.type)) throw new TypeError('Unsupported image type')
  if (!file.size) throw new TypeError('Image is empty')
  if (file.size > MAX_IMAGE_BYTES) throw new RangeError('Image is larger than 15 MB')

  const dimensions = await imageDimensions(file)
  const headers: Record<string, string> = {
    'Content-Type': file.type,
    'X-Image-Name': encodeURIComponent(cleanImageAlt(file.name || 'Pasted image')),
  }
  if (dimensions.width) headers['X-Image-Width'] = String(dimensions.width)
  if (dimensions.height) headers['X-Image-Height'] = String(dimensions.height)

  const response = await fetch('/api/images', {
    method: 'POST',
    headers,
    body: file,
  })
  if (!response.ok) throw new Error((await response.text()) || 'Could not add image')
  return response.json()
}

const imageFiles = (files: FileList | null) =>
  files ? [...files].filter((file) => IMAGE_TYPES.has(file.type)) : []

const hasImageFiles = (transfer: DataTransfer | null) =>
  Boolean(
    transfer &&
    [...transfer.items].some(
      (item) => item.kind === 'file' && IMAGE_TYPES.has(item.type),
    ),
  )

const hasImageItem = (transfer: DataTransfer | null) =>
  Boolean(
    draggedImageItem &&
    transfer &&
    [...transfer.types].includes(IMAGE_ITEM_MIME),
  )

const serializeInline = (node: Node): string => {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent || ''
  if (!(node instanceof HTMLElement)) return ''
  if (node.tagName === 'BR') return '\n'
  if (node.dataset.tweetUrl) return node.dataset.tweetUrl
  if (node.tagName === 'IMG') {
    const id = node.dataset.imageId || ''
    if (!/^[a-f0-9]{64}$/.test(id)) return ''
    return `![${cleanImageAlt(node.getAttribute('alt') || 'Image')}](noterepo:image:${id})`
  }
  if (node.tagName === 'A') {
    const label = node.textContent || ''
    const url = node.dataset.url || node.getAttribute('href') || ''
    return label === url ? url : `[${label}](${url})`
  }
  return [...node.childNodes].map(serializeInline).join('')
}

const upgradeTweetItems = (editor: HTMLElement) => {
  const upgraded: HTMLLIElement[] = []
  for (const item of editor.querySelectorAll<HTMLLIElement>('li:not(.note-tweet-item)')) {
    const body = [...item.childNodes]
      .filter((node) => !(node instanceof HTMLElement && /^(UL|OL)$/.test(node.tagName)))
      .map(serializeInline)
      .join('')
    const tweet = tweetDetails(body)
    if (!tweet) continue
    item.classList.add('note-tweet-item')
    const nested = [...item.children].filter((node) => /^(UL|OL)$/.test(node.tagName))
    item.replaceChildren(createTweetPreview(tweet), ...nested)
    upgraded.push(item)
  }
  return upgraded
}

const itemAfter = (item: HTMLLIElement) => {
  const next = item.nextElementSibling
  if (next instanceof HTMLLIElement && isEmptyListItem(next)) return next
  const empty = document.createElement('li')
  empty.append(document.createElement('br'))
  item.after(empty)
  return empty
}

const placeCaretIn = (item: HTMLLIElement) => {
  const range = document.createRange()
  range.setStart(item, 0)
  range.collapse(true)
  window.getSelection()?.removeAllRanges()
  window.getSelection()?.addRange(range)
}

const ensureItemAfterLastTweet = (editor: HTMLElement) => {
  const last = editor.lastElementChild
  const item = last && /^(UL|OL)$/.test(last.tagName) ? last.lastElementChild : null
  if (item instanceof HTMLLIElement && item.matches('.note-tweet-item')) itemAfter(item)
}

const loadTweetPreviews = async (editor: HTMLElement) => {
  const previews = [
    ...editor.querySelectorAll<HTMLElement>('.tweet-preview:not([data-preview-state])'),
  ]
  if (!previews.length) return
  previews.forEach((preview) => {
    preview.dataset.previewState = 'loading'
  })

  try {
    const twitter = await loadTweetWidgets()
    await Promise.all(
      previews.map(async (preview) => {
        const id = preview.dataset.tweetId
        const embed = preview.querySelector<HTMLElement>('.tweet-preview-embed')
        if (!id || !embed) return
        const widget = await twitter.widgets.createTweet(id, embed, {
          conversation: 'none',
          dnt: true,
          theme: tweetTheme(),
        })
        if (!widget) throw new Error('X post is unavailable')
        preview.dataset.previewState = 'loaded'
        preview.classList.add('is-loaded')
      }),
    )
  } catch (error) {
    console.warn(error)
    previews.forEach((preview) => {
      if (preview.dataset.previewState === 'loaded') return
      preview.dataset.previewState = 'unavailable'
      preview.classList.add('is-unavailable')
      const status = preview.querySelector<HTMLElement>('.tweet-preview-summary span')
      if (status) status.textContent = 'Preview unavailable · Open on X'
    })
  }
}

const reloadTweetPreviews = () => {
  const editors = new Set<HTMLElement>()
  for (const preview of document.querySelectorAll<HTMLElement>(
    '.tweet-preview[data-preview-state="loaded"]',
  )) {
    preview.querySelector('.tweet-preview-embed')?.replaceChildren()
    preview.classList.remove('is-loaded')
    delete preview.dataset.previewState
    const editor = preview.closest<HTMLElement>('.note-editor-body')
    if (editor) editors.add(editor)
  }
  editors.forEach((editor) => void loadTweetPreviews(editor))
}

lightScheme.addEventListener('change', reloadTweetPreviews)

const isList = (node: Node): node is HTMLElement =>
  node instanceof HTMLElement && /^(UL|OL)$/.test(node.tagName)

const serializeList = (list: HTMLElement, depth: number, lines: string[]) => {
  const ordered = list.tagName === 'OL'
  const start = ordered ? Number(list.getAttribute('start') || 1) : 1
  const indent = '  '.repeat(depth)
  const items = [...list.children].filter((item) => item.tagName === 'LI')
  items.forEach((item, index) => {
    const marker = ordered ? `${start + index}.` : '-'
    const body = [...item.childNodes]
      .filter((node) => !isList(node))
      .map(serializeInline)
      .join('')
    const visibleBody = body.replaceAll('\n', '').trim()
    if (visibleBody) lines.push(`${indent}${marker} ${body}`.trimEnd())
    else lines.push(depth ? `${indent}${marker}` : '')
    for (const nested of item.children) {
      if (isList(nested)) serializeList(nested, depth + 1, lines)
    }
  })
}

const caretPosition = (editor: HTMLElement): CaretPosition | null => {
  const selection = window.getSelection()
  if (!selection?.rangeCount || !editor.contains(selection.anchorNode)) return null
  const items = [...editor.querySelectorAll('li')]
  const item = closestListItem(editor, selection.anchorNode)
  if (!item) return null
  const range = document.createRange()
  range.selectNodeContents(item)
  range.setEnd(selection.anchorNode as Node, selection.anchorOffset)
  return { item: items.indexOf(item), offset: range.toString().length }
}

const restoreCaret = (editor: HTMLElement, caret: CaretPosition) => {
  const items = editor.querySelectorAll('li')
  const item = items[Math.min(caret.item, items.length - 1)]
  if (!item) return
  const range = document.createRange()
  range.setStart(item, 0)
  const walker = document.createTreeWalker(item, NodeFilter.SHOW_TEXT)
  let remaining = caret.offset
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const length = node.textContent?.length || 0
    range.setStart(node, Math.min(remaining, length))
    if (remaining <= length) break
    remaining -= length
  }
  range.collapse(true)
  window.getSelection()?.removeAllRanges()
  window.getSelection()?.addRange(range)
}

const keepScrollPosition = (change: () => void) => {
  const feed = document.querySelector<HTMLElement>('#daily-feed')
  const top = feed?.getBoundingClientRect().top || 0
  const anchor = [...document.querySelectorAll<HTMLElement>('[data-note-date]')].find(
    (section) => section.getBoundingClientRect().bottom > top,
  )
  const offset = anchor?.getBoundingClientRect().top || 0
  change()
  const shift = anchor?.isConnected ? anchor.getBoundingClientRect().top - offset : 0
  if (feed && shift) feed.scrollTop += shift
}

const serializeEditor = (editor: HTMLElement) => {
  const lines: string[] = []
  for (const child of editor.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      lines.push(child.textContent || '')
      continue
    }
    if (!(child instanceof HTMLElement)) continue
    if (isList(child)) {
      serializeList(child, 0, lines)
      continue
    }
    lines.push(serializeInline(child).replace(/\n$/, ''))
  }
  return lines.join('\n').replaceAll('\u00a0', ' ')
}

window.noteShell = () => ({
  activeDate: todayKey(),
  saveState: 'saved',
  saveLabel: '',
  searchOpen: false,
  pendingJump: todayKey(),
  pendingFocusDate: '',
  feedBound: false,
  scrollFrame: 0,
  prependSnapshot: null as null | { height: number; top: number },

  init() {
    document.body.addEventListener('htmx:beforeSwap', (event: Event) => {
      const target = (event as CustomEvent).detail.target as HTMLElement
      if (target?.dataset?.direction !== 'before') return
      const feed = document.querySelector<HTMLElement>('#daily-feed')
      if (feed) this.prependSnapshot = { height: feed.scrollHeight, top: feed.scrollTop }
    })

    document.body.addEventListener('htmx:afterSwap', (event: Event) => {
      const target = (event as CustomEvent).detail.target as HTMLElement
      requestAnimationFrame(() => {
        Alpine.initTree(target)
        this.bindFeed()

        if (target?.dataset?.direction === 'before' && this.prependSnapshot) {
          const feed = document.querySelector<HTMLElement>('#daily-feed')
          if (feed) {
            feed.scrollTop =
              this.prependSnapshot.top + (feed.scrollHeight - this.prependSnapshot.height)
          }
          this.prependSnapshot = null
        }

        if (target?.id === 'daily-feed' && this.pendingJump) {
          const date = this.pendingJump
          this.pendingJump = ''
          if (!this.scrollToLoadedDate(date, false)) this.scrollToClosestDate(date)
          if (this.pendingFocusDate === date) this.focusLoadedDate(date)
        } else {
          this.updateActiveFromScroll()
        }
      })
    })

    window.addEventListener('noterepo:focus-day', ((event: CustomEvent) => {
      const section = document.querySelector<HTMLElement>(`[data-note-date="${event.detail.date}"]`)
      if (section) this.setActiveFromSection(section)
    }) as EventListener)

    window.addEventListener('noterepo:save-state', ((event: CustomEvent) => {
      if (event.detail.date !== this.activeDate) return
      this.saveState = event.detail.state
      this.saveLabel = event.detail.label
    }) as EventListener)

    window.desktop?.onNotesChanged((dates) => {
      outsideChanges = outsideChanges.then(() => this.refreshDays(dates)).catch(console.error)
    })

    window.desktop?.onOpenDay((date) => {
      this.jumpToDate(date === 'today' ? todayKey() : date, true, false)
    })
  },

  async refreshDays(dates: string[]) {
    const days = dates.filter((date) => date <= todayKey())
    if (days.length > 10) {
      await this.refreshFeed()
      return
    }
    for (const date of days) await this.refreshDay(date)
    this.updateActiveFromScroll()
  },

  async refreshDay(date: string) {
    const response = await fetch(`/api/day/${date}?format=json`)
    if (!response.ok) return
    const note = (await response.json()) as StoredNote
    const section = document.querySelector<HTMLElement>(`[data-note-date="${date}"]`)

    if (section) {
      const editor = window.Alpine.$data(section)
      if (note.content === editor.base) return
      if (editor.content !== editor.lastSaved) {
        await editor.save()
        return
      }
      if (!note.hasContent && date !== todayKey()) keepScrollPosition(() => section.remove())
      else keepScrollPosition(() => editor.applyContent(note.content, note.html))
      return
    }

    if (!note.hasContent) return
    const sections = [...document.querySelectorAll<HTMLElement>('[data-note-date]')]
    const next = sections.find((candidate) => (candidate.dataset.noteDate || '') > date)
    if (!next) return
    if (next === sections[0] && document.querySelector('.feed-sentinel[data-direction="before"]')) return

    const template = document.createElement('template')
    template.innerHTML = (await fetch(`/api/day/${date}`).then((day) => day.text())).trim()
    const added = template.content.firstElementChild as HTMLElement | null
    if (!added) return
    keepScrollPosition(() => next.before(added))
    await new Promise((resolve) => setTimeout(resolve, 20))
    if (!(added as HTMLElement & { _x_dataStack?: unknown })._x_dataStack) window.Alpine.initTree(added)
  },

  async refreshFeed() {
    const editors = [...document.querySelectorAll<HTMLElement>('[data-note-date]')].map((section) =>
      window.Alpine.$data(section),
    )
    await Promise.all(
      editors.filter((editor) => editor.content !== editor.lastSaved).map((editor) => editor.save()),
    )
    this.pendingJump = this.activeDate
    this.reloadFeed(this.activeDate)
  },

  today() {
    return todayKey()
  },

  bindFeed() {
    if (this.feedBound) return
    const feed = document.querySelector<HTMLElement>('#daily-feed')
    if (!feed) return
    feed.addEventListener('scroll', () => {
      cancelAnimationFrame(this.scrollFrame)
      this.scrollFrame = requestAnimationFrame(() => this.updateActiveFromScroll())
    })
    this.feedBound = true
  },

  updateActiveFromScroll() {
    const feed = document.querySelector<HTMLElement>('#daily-feed')
    const sections = [...document.querySelectorAll<HTMLElement>('[data-note-date]')]
    if (!feed || !sections.length) return

    const marker = feed.getBoundingClientRect().top + 40
    let active = sections[0]
    for (const section of sections) {
      if (section.getBoundingClientRect().top <= marker) active = section
      else break
    }
    this.setActiveFromSection(active)
  },

  setActiveFromSection(section: HTMLElement) {
    const date = section.dataset.noteDate
    if (date) this.activeDate = date
  },

  scrollToLoadedDate(dateKey: string, smooth = true) {
    const section = document.querySelector<HTMLElement>(`[data-note-date="${dateKey}"]`)
    if (!section) return false
    section.scrollIntoView({ behavior: smooth ? 'smooth' : 'auto', block: 'start' })
    this.setActiveFromSection(section)
    return true
  },

  scrollToClosestDate(dateKey: string) {
    const sections = [...document.querySelectorAll<HTMLElement>('[data-note-date]')]
    if (!sections.length) return false
    const targetTime = fromDateKey(dateKey).getTime()
    const closest = sections.reduce((best, section) => {
      const sectionTime = fromDateKey(section.dataset.noteDate || dateKey).getTime()
      const bestTime = fromDateKey(best.dataset.noteDate || dateKey).getTime()
      return Math.abs(sectionTime - targetTime) < Math.abs(bestTime - targetTime)
        ? section
        : best
    })
    closest.scrollIntoView({ behavior: 'auto', block: 'start' })
    this.setActiveFromSection(closest)
    return true
  },

  focusLoadedDate(dateKey: string) {
    const editor = document.querySelector<HTMLElement>(
      `[data-note-date="${dateKey}"] [contenteditable="true"]`,
    )
    if (!editor) return
    this.pendingFocusDate = ''
    requestAnimationFrame(() => {
      editor.focus({ preventScroll: true })
      const range = document.createRange()
      range.selectNodeContents(editor)
      range.collapse(false)
      const selection = window.getSelection()
      selection?.removeAllRanges()
      selection?.addRange(range)
    })
  },

  reloadFeed(anchor: string) {
    htmx.ajax('get', `/api/feed?anchor=${encodeURIComponent(anchor)}`, {
      target: '#daily-feed',
      swap: 'innerHTML',
    })
  },

  jumpToDate(dateKey: string, focusEditor = false, smooth = true) {
    if (!dateKey) return
    const date = dateKey < todayKey() ? dateKey : todayKey()
    this.searchOpen = false
    if (focusEditor) this.pendingFocusDate = date
    if (this.scrollToLoadedDate(date, smooth)) {
      if (focusEditor) this.focusLoadedDate(date)
      return
    }
    this.pendingJump = date
    this.reloadFeed(date)
  },

  jumpToNote(dateKey: string) {
    this.jumpToDate(dateKey)
  },

  focusToday() {
    this.jumpToDate(todayKey(), true)
  },

  moveDay(direction: number) {
    const sections = [...document.querySelectorAll<HTMLElement>('[data-note-date]')]
    const activeIndex = sections.findIndex(
      (section) => section.dataset.noteDate === this.activeDate,
    )
    const target = sections[activeIndex + direction]
    if (target?.dataset.noteDate) this.scrollToLoadedDate(target.dataset.noteDate)
  },

  handleShortcut(event: KeyboardEvent) {
    if (event.defaultPrevented) return
    if (event.metaKey && event.key.toLowerCase() === 'k') {
      event.preventDefault()
      this.searchOpen = true
      document.querySelector<HTMLInputElement>('#note-search')?.focus()
      return
    }
    if (event.metaKey && event.key.toLowerCase() === 'd') {
      event.preventDefault()
      this.focusToday()
      return
    }
    if (event.altKey && event.key === 'ArrowUp') {
      event.preventDefault()
      this.moveDay(-1)
    }
    if (event.altKey && event.key === 'ArrowDown') {
      event.preventDefault()
      this.moveDay(1)
    }
  },
})

window.noteEditor = (date: string) => ({
  date,
  content: '',
  lastSaved: '',
  base: '',
  saveTimer: 0,
  imageDragActive: false,
  uploadingImages: 0,

  mount() {
    const editor = this.$refs.editor as HTMLElement
    upgradeTweetItems(editor)
    ensureItemAfterLastTweet(editor)
    this.content = serializeEditor(editor)
    this.lastSaved = this.content
    this.base = (this.$root as HTMLElement).dataset.base ?? this.content
    void loadTweetPreviews(editor)
  },

  applyContent(content: string, html: string) {
    const editor = this.$refs.editor as HTMLElement
    const caret = document.activeElement === editor ? caretPosition(editor) : null
    editor.innerHTML = html
    upgradeTweetItems(editor)
    ensureItemAfterLastTweet(editor)
    this.content = serializeEditor(editor)
    this.lastSaved = this.content
    this.base = content
    if (caret) restoreCaret(editor, caret)
    void loadTweetPreviews(editor)
  },

  focusDay() {
    window.dispatchEvent(new CustomEvent('noterepo:focus-day', { detail: { date: this.date } }))
  },

  contentChanged() {
    const editor = this.$refs.editor as HTMLElement
    this.content = serializeEditor(editor)
    window.dispatchEvent(
      new CustomEvent('noterepo:save-state', {
        detail: { date: this.date, state: 'saving', label: 'Saving…' },
      }),
    )
    window.clearTimeout(this.saveTimer)
    this.saveTimer = window.setTimeout(() => this.save(), 300)
  },

  async save() {
    window.clearTimeout(this.saveTimer)
    if (this.content === this.lastSaved) return
    const content = this.content
    try {
      const response = await fetch(`/api/day/${this.date}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ content, base: this.base }),
      })
      if (!response.ok) throw new Error('Save failed')
      const saved = (await response.json()) as { content: string; html?: string }
      this.lastSaved = content
      if (!saved.html) this.base = saved.content
      else if (this.content === content) this.applyContent(saved.content, saved.html)
      else this.base = content
      window.dispatchEvent(
        new CustomEvent('noterepo:save-state', {
          detail: { date: this.date, state: 'saved', label: 'Saved' },
        }),
      )
    } catch {
      window.dispatchEvent(
        new CustomEvent('noterepo:save-state', {
          detail: { date: this.date, state: 'error', label: 'Could not save' },
        }),
      )
    }
  },

  async addImages(files: File[], insertionPoint?: ImageInsertionPoint) {
    if (!files.length) return
    const editor = this.$refs.editor as HTMLElement
    this.uploadingImages += files.length
    window.dispatchEvent(
      new CustomEvent('noterepo:save-state', {
        detail: { date: this.date, state: 'saving', label: 'Adding image…' },
      }),
    )

    try {
      const uploaded = await Promise.all(files.map(uploadImage))
      let insertion = insertionPoint || insertionAtRange(editor, editorRange(editor))
      for (const image of uploaded) insertion = insertImageItem(editor, insertion, image)
      this.contentChanged()
      await this.save()
    } catch (error) {
      console.error(error)
      window.dispatchEvent(
        new CustomEvent('noterepo:save-state', {
          detail: { date: this.date, state: 'error', label: 'Could not add image' },
        }),
      )
    } finally {
      this.uploadingImages = Math.max(0, this.uploadingImages - files.length)
    }
  },

  async handlePaste(event: ClipboardEvent) {
    const images = imageFiles(event.clipboardData?.files || null)
    if (images.length) {
      event.preventDefault()
      this.focusDay()
      const editor = this.$refs.editor as HTMLElement
      await this.addImages(images, insertionAtRange(editor, editorRange(editor)))
      return
    }

    const clipboardText = event.clipboardData?.getData('text/plain')
    if (!clipboardText) return
    event.preventDefault()
    const text = cleanPastedText(clipboardText)
    if (!text) return

    if (/^https?:\/\/\S+$/i.test(text) && !tweetDetails(text)) {
      const link = createLink(text)
      insertAtSelection(link)
      const item = link.closest('li')
      if (item && item.textContent?.trim() === link.textContent) placeCaretIn(itemAfter(item))
      this.contentChanged()
      void this.addLinkTitle(link)
      return
    }

    const template = document.createElement('template')
    template.innerHTML = text.split('\n').map(linkifyHtml).join('<br>')
    insertAtSelection(template.content)
    const editor = this.$refs.editor as HTMLElement
    const tweet = upgradeTweetItems(editor).at(-1)
    if (tweet) placeCaretIn(itemAfter(tweet))
    this.contentChanged()
    void loadTweetPreviews(editor)
  },

  async addLinkTitle(link: HTMLAnchorElement) {
    const url = link.dataset.url || ''
    const title = await fetchLinkTitle(url)
    if (!title || !link.isConnected || link.textContent !== url) return
    showLinkTitle(link, title)
    this.contentChanged()
  },

  imageDragEntered(event: DragEvent) {
    if (!hasImageFiles(event.dataTransfer) && !hasImageItem(event.dataTransfer)) return
    event.preventDefault()
    this.imageDragActive = true
  },

  imageDragOver(event: DragEvent) {
    const movingItem = hasImageItem(event.dataTransfer)
    if (!hasImageFiles(event.dataTransfer) && !movingItem) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = movingItem ? 'move' : 'copy'
    this.imageDragActive = true
    if (movingItem) showDropPosition(insertionAtDrop(this.$refs.editor as HTMLElement, event))
  },

  imageDragLeft(event: DragEvent) {
    const editor = this.$refs.editor as HTMLElement
    const related = event.relatedTarget
    if (!(related instanceof Node) || !editor.contains(related)) {
      this.imageDragActive = false
      clearDropPosition()
    }
  },

  async dropImages(event: DragEvent) {
    const movingItem = hasImageItem(event.dataTransfer)
    const images = imageFiles(event.dataTransfer?.files || null)
    if (!movingItem && !images.length) return

    event.preventDefault()
    this.imageDragActive = false
    const editor = this.$refs.editor as HTMLElement
    this.focusDay()
    const insertion = insertionAtDrop(editor, event)
    clearDropPosition()

    if (movingItem && draggedImageItem) {
      const item = draggedImageItem
      const sourceEditor = item.closest<HTMLElement>('.note-editor-body')
      const sourceList = item.parentElement
      appendBulletItem(editor, item, insertion)
      if (sourceList && !sourceList.children.length) sourceList.remove()
      if (sourceEditor && sourceEditor !== editor) {
        ensureEditorHasItem(sourceEditor)
        dispatchEditorInput(sourceEditor)
      }
      this.contentChanged()
      await this.save()
      return
    }

    await this.addImages(images, insertion)
  },

  startImageItemDrag(event: DragEvent) {
    const editor = this.$refs.editor as HTMLElement
    const item = closestListItem(editor, event.target as Node)
    if (!item?.matches('.note-image-item')) return
    draggedImageItem = item
    item.classList.add('is-dragging')
    if (!event.dataTransfer) return
    event.dataTransfer.effectAllowed = 'move'
    event.dataTransfer.setData(IMAGE_ITEM_MIME, this.date)
    event.dataTransfer.setData('text/plain', item.querySelector('img')?.alt || 'Image')
  },

  finishImageItemDrag() {
    draggedImageItem?.classList.remove('is-dragging')
    draggedImageItem = null
    this.imageDragActive = false
    clearDropPosition()
  },

  async openEditorLink(event: MouseEvent) {
    const target = event.target as HTMLElement
    const editor = this.$refs.editor as HTMLElement
    const imageItem = target.closest<HTMLLIElement>('.note-image-item')
    if (imageItem && editor.contains(imageItem)) {
      event.preventDefault()
      selectImage(editor, imageItem)
      return
    }

    clearSelectedImage()
    const anchor = target.closest<HTMLAnchorElement>('a[data-url]')
    if (!anchor) return
    event.preventDefault()
    const url = anchor.dataset.url
    if (!url) return
    if (window.desktop) await window.desktop.openExternal(url)
    else window.open(url, '_blank', 'noopener,noreferrer')
  },

  editorShortcut(event: KeyboardEvent) {
    const editor = this.$refs.editor as HTMLElement
    if (
      (event.key === 'Backspace' || event.key === 'Delete') &&
      selectedImageItem &&
      editor.contains(selectedImageItem)
    ) {
      event.preventDefault()
      const item = selectedImageItem
      const list = item.parentElement
      clearSelectedImage()
      item.remove()
      if (list && !list.children.length) list.remove()
      ensureEditorHasItem(editor)

      const range = document.createRange()
      range.selectNodeContents(editor)
      range.collapse(false)
      const selection = window.getSelection()
      selection?.removeAllRanges()
      selection?.addRange(range)
      this.contentChanged()
      return
    }

    if (event.key === 'Tab' && !event.metaKey && !event.altKey && !event.ctrlKey) {
      if (!caretListItem(editor)) return
      event.preventDefault()
      if (moveListItem(editor, event.shiftKey)) this.contentChanged()
      return
    }

    if (event.key !== ' ' || event.metaKey || event.altKey || event.ctrlKey) return
    const selection = window.getSelection()
    const anchorElement =
      selection?.anchorNode instanceof HTMLElement
        ? selection.anchorNode
        : selection?.anchorNode?.parentElement
    const block = anchorElement?.closest<HTMLElement>('div, p')
    if (!block || block === editor || !editor.contains(block)) return

    const marker = (block.textContent || '').trim()
    const ordered = marker.match(/^(\d+)\.$/)
    if (marker !== '-' && !ordered) return

    event.preventDefault()
    const list = document.createElement(ordered ? 'ol' : 'ul')
    if (ordered && Number(ordered[1]) !== 1) list.setAttribute('start', ordered[1])
    const item = document.createElement('li')
    item.append(document.createElement('br'))
    list.append(item)
    block.replaceWith(list)

    const range = document.createRange()
    range.selectNodeContents(item)
    range.collapse(true)
    selection?.removeAllRanges()
    selection?.addRange(range)
    this.contentChanged()
  },
})

window.Alpine = Alpine
Alpine.start()
