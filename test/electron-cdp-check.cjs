const assert = require('node:assert/strict')

const debuggerUrl = process.argv[2]
if (!debuggerUrl) throw new Error('Pass the Electron page WebSocket URL')

const socket = new WebSocket(debuggerUrl)
const pending = new Map()
let nextId = 1

const opened = new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, { once: true })
  socket.addEventListener('error', reject, { once: true })
})

socket.addEventListener('message', (event) => {
  const message = JSON.parse(event.data)
  if (!message.id || !pending.has(message.id)) return
  const { resolve, reject } = pending.get(message.id)
  pending.delete(message.id)
  if (message.error) reject(new Error(message.error.message))
  else resolve(message.result)
})

const call = async (method, params = {}) => {
  await opened
  const id = nextId++
  const result = new Promise((resolve, reject) => pending.set(id, { resolve, reject }))
  socket.send(JSON.stringify({ id, method, params }))
  return result
}

const evaluate = async (expression) => {
  const result = await call('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  })
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text)
  return result.result.value
}

const run = async () => {
  await call('Runtime.enable')
  const checks = await evaluate(`(async () => {
    const wait = (duration) => new Promise((resolve) => setTimeout(resolve, duration))
    for (let attempt = 0; attempt < 50 && !document.querySelector('[data-note-date] [contenteditable]'); attempt += 1) {
      await wait(50)
    }

    const pad = (value) => String(value).padStart(2, '0')
    const now = new Date()
    const today = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate())
    const editor = document.querySelector('[data-note-date="' + today + '"] [contenteditable]')
    if (!editor) throw new Error('Today editor did not load')
    const originalHtml = editor.innerHTML
    const day = editor.closest('.day-note')
    const feed = document.querySelector('#daily-feed')
    const todayFillsFeed = day.getBoundingClientRect().height >= feed.clientHeight - 1

    const placeCaretAtEnd = (element) => {
      const range = document.createRange()
      range.selectNodeContents(element)
      range.collapse(false)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    }

    const nextDate = '1999-12-29'
    const nextSectionHtml = await fetch('/api/day/' + nextDate).then((response) => response.text())
    if (!nextSectionHtml.includes('<ul><li><br></li></ul>')) throw new Error(nextDate + ' already has a note')
    day.insertAdjacentHTML('beforebegin', nextSectionHtml)
    const nextSection = day.previousElementSibling
    await wait(20)
    if (!nextSection._x_dataStack) window.Alpine.initTree(nextSection)
    const nextEditor = nextSection.querySelector('[contenteditable]')
    const nextOriginalHtml = nextEditor.innerHTML
    const pastDayCompact = nextSection.getBoundingClientRect().height < 200
    try {
      nextEditor.focus()
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', metaKey: true, bubbles: true, cancelable: true }))
      await wait(80)
      const commandDFocusedToday = document.activeElement === editor

      editor.innerHTML = '<div>-</div>'
      editor.focus()
      placeCaretAtEnd(editor.firstElementChild)
      editor.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }))
      await wait(20)
      const unorderedList = Boolean(editor.querySelector('ul > li'))

      editor.innerHTML = '<div>1.</div>'
      editor.focus()
      placeCaretAtEnd(editor.firstElementChild)
      editor.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true, cancelable: true }))
      await wait(20)
      const orderedList = Boolean(editor.querySelector('ol > li'))

      editor.innerHTML = '<div><br></div>'
      editor.focus()
      placeCaretAtEnd(editor.firstElementChild)
      const clipboard = new DataTransfer()
      clipboard.setData('text/plain', 'https://example.com')
      editor.dispatchEvent(new ClipboardEvent('paste', {
        clipboardData: clipboard,
        bubbles: true,
        cancelable: true,
      }))
      await wait(20)
      const anchor = editor.querySelector('a[data-url="https://example.com"]')
      const style = anchor ? getComputedStyle(anchor) : null
      const pastedLink = Boolean(anchor)
      const blueUnderlined = Boolean(
        style &&
        style.textDecorationLine.includes('underline') &&
        style.color !== 'rgba(255, 255, 255, 0.82)'
      )
      const addLinkRemoved = !document.body.innerText.includes('ADD LINK')

      const pasteText = (text) => {
        const data = new DataTransfer()
        data.setData('text/plain', text)
        editor.dispatchEvent(new ClipboardEvent('paste', {
          clipboardData: data,
          bubbles: true,
          cancelable: true,
        }))
      }

      editor.innerHTML = '<ul><li><br></li></ul>'
      editor.focus()
      placeCaretAtEnd(editor)
      pasteText('\\r\\n\\u200b  Buy oat milk  \\r\\n\\r\\n')
      await wait(20)
      const cleanedPaste = editor.innerHTML === '<ul><li>Buy oat milk<br></li></ul>'

      editor.innerHTML = '<ul><li>Call Anna <br></li></ul>'
      editor.focus()
      placeCaretAtEnd(editor.querySelector('li'))
      pasteText('tomorrow')
      await wait(20)
      const pastedOnSameLine = editor.innerHTML === '<ul><li>Call Anna tomorrow<br></li></ul>'

      editor.innerHTML = '<ul><li>Call Anna</li></ul><div><br></div>'
      editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertParagraph' }))
      let blankLineSavedOnce = false
      for (let attempt = 0; attempt < 30 && !blankLineSavedOnce; attempt += 1) {
        await wait(50)
        const savedDay = await fetch('/api/day/' + today).then((response) => response.text())
        blankLineSavedOnce = savedDay.includes('<ul><li>Call Anna</li><li><br></li></ul></div>')
      }

      editor.innerHTML = '<ul><li><br></li></ul>'
      editor.focus()
      placeCaretAtEnd(editor)
      const pageUrl = location.origin + '/'
      pasteText('\\n' + pageUrl + '\\n')
      const caretInItemAfterLink = () => {
        const next = editor.querySelector('li')?.nextElementSibling
        return Boolean(
          next?.tagName === 'LI' && !next.textContent.trim() && next.contains(getSelection().anchorNode)
        )
      }
      const newItemAfterLink = caretInItemAfterLink()
      let titledItem = null
      for (let attempt = 0; attempt < 50 && !titledItem; attempt += 1) {
        const item = editor.querySelector('li')
        if (item?.textContent === 'NoteRepo (' + location.hostname + ')') titledItem = item
        else await wait(50)
      }
      const pastedLinkTitle = Boolean(
        titledItem?.querySelector('a[data-url="' + pageUrl + '"]')?.textContent === 'NoteRepo'
      )
      const caretStayedAfterTitle = caretInItemAfterLink()
      let linkTitleSaved = false
      for (let attempt = 0; attempt < 30 && !linkTitleSaved; attempt += 1) {
        const savedDay = await fetch('/api/day/' + today).then((response) => response.text())
        linkTitleSaved = savedDay.includes('>NoteRepo</a> (' + location.hostname + ')')
        if (!linkTitleSaved) await wait(50)
      }

      editor.innerHTML = '<ul><li>Read </li></ul>'
      editor.focus()
      placeCaretAtEnd(editor.querySelector('li'))
      pasteText(pageUrl)
      await wait(20)
      const inlineLinkStaysInline = editor.querySelectorAll('li').length === 1

      editor.innerHTML = '<ul><li><br></li></ul>'
      editor.focus()
      placeCaretAtEnd(editor.querySelector('li'))
      const tweetUrl = 'https://x.com/dhh/status/2087272392557007042'
      const tweetClipboard = new DataTransfer()
      tweetClipboard.setData('text/plain', tweetUrl)
      editor.dispatchEvent(new ClipboardEvent('paste', {
        clipboardData: tweetClipboard,
        bubbles: true,
        cancelable: true,
      }))
      await wait(50)
      const tweetPreviewElement = editor.querySelector('.tweet-preview[data-tweet-id="2087272392557007042"]')
      const tweetPreview = Boolean(tweetPreviewElement)
      const tweetPreviewClickable = Boolean(
        tweetPreviewElement?.querySelector('a.tweet-preview-link[data-url="' + tweetUrl + '"]')
      )
      const itemAfterTweet = tweetPreviewElement?.closest('li')?.nextElementSibling
      const caretBelowTweet = Boolean(
        itemAfterTweet?.tagName === 'LI' &&
        !itemAfterTweet.textContent.trim() &&
        itemAfterTweet.contains(getSelection().anchorNode)
      )
      const previewStyle = tweetPreviewElement ? getComputedStyle(tweetPreviewElement) : null
      const tweetBulletOnTop = previewStyle?.display === 'inline-block' && previewStyle.verticalAlign === 'top'
      let tweetLivePreview = false
      for (let attempt = 0; attempt < 100 && !tweetLivePreview; attempt += 1) {
        tweetLivePreview = Boolean(
          tweetPreviewElement?.classList.contains('is-loaded') &&
          tweetPreviewElement.querySelector('.tweet-preview-embed iframe')
        )
        if (!tweetLivePreview) await wait(100)
      }
      const cardBounds = tweetPreviewElement?.getBoundingClientRect()
      const iframeBounds = tweetPreviewElement?.querySelector('iframe')?.getBoundingClientRect()
      const tweetBorderHugsCard = Boolean(
        cardBounds && iframeBounds &&
        Math.abs(cardBounds.top - iframeBounds.top) <= 1 &&
        Math.abs(cardBounds.bottom - iframeBounds.bottom) <= 1
      )
      const embedStyle = tweetPreviewElement
        ? getComputedStyle(tweetPreviewElement.querySelector('.tweet-preview-embed'))
        : null
      const tweetCornersClipped = embedStyle?.overflow === 'hidden' && embedStyle.borderRadius === '12px'
      let tweetPreviewSaved = false
      for (let attempt = 0; attempt < 30 && !tweetPreviewSaved; attempt += 1) {
        const savedDay = await fetch('/api/day/' + today).then((response) => response.text())
        tweetPreviewSaved = savedDay.includes('data-tweet-id="2087272392557007042"')
        if (!tweetPreviewSaved) await wait(50)
      }

      const pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
      const pngBinary = atob(pngBase64)
      const pngBytes = Uint8Array.from(pngBinary, (character) => character.charCodeAt(0))
      const imageFile = () => new File([pngBytes], 'tiny image.png', { type: 'image/png' })

      editor.innerHTML = '<div><br></div>'
      editor.focus()
      placeCaretAtEnd(editor.firstElementChild)
      const dragData = new DataTransfer()
      dragData.items.add(imageFile())
      editor.dispatchEvent(new DragEvent('dragenter', {
        dataTransfer: dragData,
        bubbles: true,
        cancelable: true,
      }))
      await wait(20)
      const imageDropCue = editor.classList.contains('is-image-drop-target')

      editor.dispatchEvent(new DragEvent('drop', {
        dataTransfer: dragData,
        bubbles: true,
        cancelable: true,
      }))
      for (let attempt = 0; attempt < 50 && editor.querySelectorAll('img[data-image-id]').length < 1; attempt += 1) {
        await wait(50)
      }
      const droppedImage = editor.querySelector('img[data-image-id]')
      const droppedImageItem = droppedImage?.closest('li.note-image-item')
      const imageIsListItem = Boolean(
        droppedImageItem &&
        droppedImageItem.parentElement?.tagName === 'UL' &&
        droppedImageItem.draggable
      )
      const imageResponse = droppedImage ? await fetch(droppedImage.getAttribute('src')) : null
      const imageStored = Boolean(imageResponse?.ok && (await imageResponse.arrayBuffer()).byteLength)

      nextEditor.innerHTML = '<ul><li>Move image here</li></ul>'
      const moveData = new DataTransfer()
      droppedImageItem.dispatchEvent(new DragEvent('dragstart', {
        dataTransfer: moveData,
        bubbles: true,
        cancelable: true,
      }))
      nextEditor.dispatchEvent(new DragEvent('dragover', {
        dataTransfer: moveData,
        bubbles: true,
        cancelable: true,
      }))
      nextEditor.dispatchEvent(new DragEvent('drop', {
        dataTransfer: moveData,
        bubbles: true,
        cancelable: true,
      }))
      droppedImageItem.dispatchEvent(new DragEvent('dragend', {
        dataTransfer: moveData,
        bubbles: true,
      }))
      await wait(500)
      const movedToOtherDay = Boolean(
        nextEditor.querySelector('li.note-image-item img[data-image-id]') === droppedImage
      )
      const movedDayHtml = await fetch('/api/day/' + nextDate).then((response) => response.text())
      const movedImageSaved = movedDayHtml.includes('class="note-image-item"')

      const imagesBeforePaste = editor.querySelectorAll('img[data-image-id]').length
      const pasteData = new DataTransfer()
      pasteData.items.add(imageFile())
      editor.focus()
      placeCaretAtEnd(editor.querySelector('li'))
      editor.dispatchEvent(new ClipboardEvent('paste', {
        clipboardData: pasteData,
        bubbles: true,
        cancelable: true,
      }))
      for (let attempt = 0; attempt < 50 && editor.querySelectorAll('img[data-image-id]').length <= imagesBeforePaste; attempt += 1) {
        await wait(50)
      }
      const pastedImage = editor.querySelectorAll('img[data-image-id]').length === imagesBeforePaste + 1
      const pastedImageItem = editor.querySelector('li.note-image-item')
      const pastedImageElement = pastedImageItem?.querySelector('img[data-image-id]')
      pastedImageElement?.dispatchEvent(new MouseEvent('click', {
        bubbles: true,
        cancelable: true,
      }))
      await wait(20)
      const selectedImage = pastedImageItem?.classList.contains('is-selected') === true
      const highlightedImage = pastedImageElement
        ? getComputedStyle(pastedImageElement).boxShadow !== 'none'
        : false
      editor.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Delete',
        bubbles: true,
        cancelable: true,
      }))
      await wait(20)
      const deletedSelectedImage = editor.querySelectorAll('img[data-image-id]').length === imagesBeforePaste

      const replacementPasteData = new DataTransfer()
      replacementPasteData.items.add(imageFile())
      editor.dispatchEvent(new ClipboardEvent('paste', {
        clipboardData: replacementPasteData,
        bubbles: true,
        cancelable: true,
      }))
      for (let attempt = 0; attempt < 50 && editor.querySelectorAll('img[data-image-id]').length <= imagesBeforePaste; attempt += 1) {
        await wait(50)
      }
      const imageStyle = droppedImage ? getComputedStyle(droppedImage) : null
      const styledImage = Boolean(
        imageStyle && imageStyle.display === 'block' && imageStyle.borderRadius !== '0px'
      )

      let renderedImage = false
      for (let attempt = 0; attempt < 50 && !renderedImage; attempt += 1) {
        const savedDay = await fetch('/api/day/' + today).then((response) => response.text())
        renderedImage = savedDay.includes('class="note-image"')
        if (!renderedImage) await wait(50)
      }

      return {
        commandDFocusedToday,
        todayFillsFeed,
        pastDayCompact,
        unorderedList,
        orderedList,
        pastedLink,
        blueUnderlined,
        addLinkRemoved,
        cleanedPaste,
        pastedOnSameLine,
        blankLineSavedOnce,
        newItemAfterLink,
        pastedLinkTitle,
        caretStayedAfterTitle,
        inlineLinkStaysInline,
        linkTitleSaved,
        tweetPreview,
        tweetPreviewClickable,
        caretBelowTweet,
        tweetBulletOnTop,
        tweetLivePreview,
        tweetBorderHugsCard,
        tweetCornersClipped,
        tweetPreviewSaved,
        imageDropCue,
        droppedImage: Boolean(droppedImage),
        imageIsListItem,
        imageStored,
        movedToOtherDay,
        movedImageSaved,
        pastedImage,
        selectedImage,
        highlightedImage,
        deletedSelectedImage,
        styledImage,
        renderedImage,
      }
    } finally {
      editor.innerHTML = originalHtml
      editor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText' }))
      nextEditor.innerHTML = nextOriginalHtml
      nextEditor.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText' }))
      await wait(500)
      nextSection.remove()
    }
  })()`)

  for (const [name, passed] of Object.entries(checks)) assert.equal(passed, true, name)
  process.stdout.write(`${JSON.stringify(checks)}\n`)
  socket.close()
}

run().catch((error) => {
  socket.close()
  console.error(error)
  process.exitCode = 1
})
