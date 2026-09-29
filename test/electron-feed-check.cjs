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

const run = async () => {
  await call('Runtime.enable')
  const expression = `(async () => {
    const wait = (duration) => new Promise((resolve) => setTimeout(resolve, duration))
    const waitFor = async (check) => {
      for (let attempt = 0; attempt < 80; attempt += 1) {
        if (check()) return true
        await wait(50)
      }
      return false
    }
    const save = (date, content) => fetch('/api/day/' + date, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content }),
    })

    const pad = (value) => String(value).padStart(2, '0')
    const now = new Date()
    const today = now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate())
    await waitFor(() => document.querySelector('[data-note-date="' + today + '"]'))

    const feed = document.querySelector('#daily-feed')
    const dates = () => [...document.querySelectorAll('[data-note-date]')].map((section) => section.dataset.noteDate)
    const todaySection = document.querySelector('[data-note-date="' + today + '"]')
    await wait(1500)
    const todayBounds = todaySection.getBoundingClientRect()
    const layout = {
      todayIsLast: dates().at(-1) === today,
      noFutureDays: dates().every((date) => date <= today),
      todayFillsScreen: todayBounds.height >= feed.clientHeight - 1,
      todayAtTop: Math.abs(todayBounds.top - feed.getBoundingClientRect().top) <= 1,
      filterRemoved: !document.body.innerText.includes('Days with notes'),
    }

    const firstDate = dates()[0]
    feed.scrollTop = 0
    layout.olderDaysLoadOnScroll = Boolean(await waitFor(() => dates()[0] < firstDate))
    await wait(100)
    layout.scrollKeptPlace = Math.abs(
      document.querySelector('[data-note-date="' + firstDate + '"]').getBoundingClientRect().top -
      feed.getBoundingClientRect().top - 40
    ) <= 2
    layout.pastDaysHaveNotes = [...document.querySelectorAll('[data-note-date]:not(.is-today) [contenteditable]')]
      .every((editor) => editor.textContent.trim() || editor.querySelector('img[data-image-id], .tweet-preview'))

    const dateInput = document.querySelector('#date-jump')
    const testDays = ['1999-12-30', '1999-12-31']
    for (const date of testDays) {
      const section = await fetch('/api/day/' + date).then((response) => response.text())
      if (!section.includes('<ul><li><br></li></ul>')) throw new Error(date + ' already has a note')
    }

    try {
      await save('1999-12-30', 'Saved test day')
      await save('1999-12-31', ' \\n\\t ')

      dateInput.value = '1999-12-31'
      dateInput.dispatchEvent(new Event('change', { bubbles: true }))
      const jumpedToClosestNote = await waitFor(() =>
        document.querySelector('[data-note-date="1999-12-30"]') && dateInput.value === '1999-12-30'
      )
      const emptyDayHidden = !document.querySelector('[data-note-date="1999-12-31"]')

      dateInput.value = '2099-01-01'
      dateInput.dispatchEvent(new Event('change', { bubbles: true }))
      const futureJumpShowsToday = await waitFor(() =>
        dateInput.value === today && dates().at(-1) === today && dates().every((date) => date <= today)
      )

      return {
        ...layout,
        futureDatesDisabled: dateInput.max === today,
        jumpedToClosestNote: Boolean(jumpedToClosestNote),
        emptyDayHidden,
        futureJumpShowsToday,
      }
    } finally {
      for (const date of testDays) await save(date, '')
    }
  })()`
  const evaluation = await call('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  })
  if (evaluation.exceptionDetails) {
    throw new Error(
      evaluation.exceptionDetails.exception?.description || evaluation.exceptionDetails.text,
    )
  }

  const checks = evaluation.result.value
  for (const [name, passed] of Object.entries(checks)) assert.equal(passed, true, name)
  process.stdout.write(`${JSON.stringify(checks)}\n`, () => {
    socket.close()
    process.exit(0)
  })
}

run().catch((error) => {
  socket.close()
  console.error(error)
  process.exit(1)
})
