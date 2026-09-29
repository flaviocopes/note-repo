const assert = require('node:assert/strict')
const os = require('node:os')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const [debuggerUrl, dataDir] = process.argv.slice(2)
if (!debuggerUrl || !dataDir) {
  throw new Error('Pass the Electron page WebSocket URL and the --user-data-dir folder the app was launched with')
}
if (path.resolve(dataDir) === path.join(os.homedir(), 'Library', 'Application Support', 'NoteRepo')) {
  throw new Error('This check resets its notebook. Launch the app with a temporary --user-data-dir')
}

const cli = path.join(__dirname, '..', 'release', 'mac-arm64', 'NoteRepo.app', 'Contents', 'Resources', 'bin', 'noterepo')
const noterepo = (...args) => JSON.parse(execFileSync(cli, ['--data-dir', dataDir, ...args], { encoding: 'utf8' }))

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
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text)
  return result.result.value
}

const sleep = (duration) => new Promise((resolve) => setTimeout(resolve, duration))

const waitFor = async (expression, label, timeout = 5000) => {
  const started = Date.now()
  while (!(await evaluate(expression))) {
    if (Date.now() - started > timeout) throw new Error(`Timed out waiting for ${label}`)
    await sleep(100)
  }
}

const pad = (value) => String(value).padStart(2, '0')
const daysAgo = (amount) => {
  const date = new Date()
  date.setDate(date.getDate() - amount)
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

const today = daysAgo(0)
const tag = `CLI check ${Date.now().toString(36)}`
const dayText = (date) => `(document.querySelector('[data-note-date="${date}"] [contenteditable]')?.textContent || '')`
const shows = (date, text) => `${dayText(date)}.includes(${JSON.stringify(text)})`
const editor = `window.Alpine.$data(document.querySelector('[data-note-date="${today}"]'))`
const typeInToday = (text) => `(async () => {
  const body = document.querySelector('[data-note-date="${today}"] [contenteditable]')
  const list = body.querySelector('ul, ol') || body.appendChild(document.createElement('ul'))
  const item = document.createElement('li')
  item.textContent = ${JSON.stringify(text)}
  list.append(item)
  ${editor}.contentChanged()
})()`

const run = async () => {
  await call('Runtime.enable')
  await evaluate('window.Alpine.$data(document.body).focusToday()')
  await waitFor(`Boolean(document.querySelector('[data-note-date="${today}"] [contenteditable]'))`, "today's editor")

  const added = `${tag}: added while the app is open`
  noterepo('add', added)
  await waitFor(shows(today, added), 'the CLI item to show up')

  const outside = `${tag}: outside change`
  const typed = `${tag}: typed in the app`
  noterepo('add', outside)
  await waitFor(shows(today, outside), 'the second CLI item')
  await evaluate(typeInToday(typed))
  await evaluate(`${editor}.save()`)
  const afterTyping = noterepo('show').content
  for (const text of [added, outside, typed]) assert.equal(afterTyping.includes(text), true, text)

  const unsaved = `${tag}: unsaved typing`
  const during = `${tag}: agent wrote during typing`
  await evaluate(typeInToday(unsaved))
  await evaluate(`clearTimeout(${editor}.saveTimer)`)
  noterepo('add', during)
  await waitFor(shows(today, during), 'the outside change to merge with unsaved typing')
  assert.equal(await evaluate(shows(today, unsaved)), true, 'unsaved typing survives the merge')
  const merged = noterepo('show').content
  assert.equal(merged.includes(unsaved), true, unsaved)
  assert.equal(merged.includes(during), true, during)

  const yesterday = daysAgo(1)
  noterepo('write', yesterday, '--content', '- CLI check: a new past day')
  await waitFor(`${dayText(yesterday)}.includes('a new past day')`, 'a new past day to appear')
  noterepo('clear', yesterday)
  await waitFor(`!document.querySelector('[data-note-date="${yesterday}"]')`, 'the cleared day to disappear')

  const earlier = daysAgo(10)
  noterepo('write', earlier, '--content', '- CLI check: open this day')
  await waitFor(`Boolean(document.querySelector('[data-note-date="${earlier}"]'))`, 'the earlier day')
  noterepo('open', earlier)
  await waitFor(`window.Alpine.$data(document.body).activeDate === '${earlier}'`, 'open to jump to the day')

  const many = Object.fromEntries(
    Array.from({ length: 12 }, (_, index) => [daysAgo(20 + index), `- ${tag}: bulk day ${index + 1}`]),
  )
  noterepo('write', '--json', '--content', JSON.stringify(many))
  await waitFor(shows(daysAgo(20), `${tag}: bulk day 1`), 'the feed to reload after a bulk write')

  const saved = noterepo('reset', '--yes')
  await waitFor(`!document.querySelector('[data-note-date="${earlier}"]')`, 'reset to empty the feed')
  noterepo('restore', saved.backup.path, '--yes')
  await waitFor(`Boolean(document.querySelector('[data-note-date="${earlier}"]'))`, 'restore to bring the days back')
  await waitFor(shows(today, during), "restore to bring today's notes back")

  console.log('CLI live checks passed')
}

run()
  .then(() => socket.close())
  .catch((error) => {
    console.error(error)
    socket.close()
    process.exitCode = 1
  })
