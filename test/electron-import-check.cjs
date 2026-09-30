const assert = require('node:assert/strict')

const debuggerUrl = process.argv[2]
const date = process.argv[3]
if (!debuggerUrl || !/^\d{4}-\d{2}-\d{2}$/.test(date || '')) {
  throw new Error('Pass the Electron page WebSocket URL and an imported date')
}

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
    for (let attempt = 0; attempt < 50 && !document.querySelector('[data-note-date]'); attempt += 1) {
      await wait(50)
    }

    window.Alpine.$data(document.body).jumpToDate(${JSON.stringify(date)})

    let section = null
    for (let attempt = 0; attempt < 80 && !section; attempt += 1) {
      section = document.querySelector('[data-note-date="${date}"]')
      if (!section) await wait(50)
    }
    const image = section?.querySelector('img[data-image-id]')
    if (image && !image.complete) {
      await Promise.race([
        image.decode().catch(() => {}),
        wait(3000),
      ])
    }
    const response = image ? await fetch(image.src) : null
    const bytes = response?.ok ? (await response.arrayBuffer()).byteLength : 0
    const style = image ? getComputedStyle(image) : null

    return {
      dayLoaded: Boolean(section),
      imageRendered: Boolean(image),
      localImage: Boolean(image?.src.includes('/api/images/')),
      imageLoaded: Boolean(image?.complete && image?.naturalWidth > 0),
      imageServed: bytes > 0,
      imageStyled: style?.display === 'block',
    }
  })()`
  const evaluation = await call('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true,
  })
  if (evaluation.exceptionDetails) throw new Error(evaluation.exceptionDetails.text)

  const checks = evaluation.result.value
  for (const [name, passed] of Object.entries(checks)) assert.equal(passed, true, name)
  process.stdout.write(`${JSON.stringify(checks)}\n`)
  socket.close()
}

run().catch((error) => {
  socket.close()
  console.error(error)
  process.exitCode = 1
})
