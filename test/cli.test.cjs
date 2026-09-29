const assert = require('node:assert/strict')
const { execFile } = require('node:child_process')
const fs = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const test = require('node:test')
const { todayKey } = require('../electron/server.cjs')

const CLI = path.join(__dirname, '..', 'bin', 'noterepo.cjs')
const PIXEL_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
)

const setupCli = async (context) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'noterepo-cli-'))
  context.after(() => fs.rm(directory, { recursive: true, force: true }))

  const run = (...args) =>
    new Promise((resolve) => {
      execFile(
        process.execPath,
        [CLI, '--data-dir', path.join(directory, 'data'), ...args],
        { env: { ...process.env, HOME: directory } },
        (error, stdout, stderr) => {
          resolve({
            code: error ? error.code : 0,
            output: stdout ? JSON.parse(stdout) : null,
            error: stderr ? JSON.parse(stderr).error : null,
          })
        },
      )
    })

  const ok = async (...args) => {
    const result = await run(...args)
    assert.equal(result.error, null)
    return result.output
  }

  return { directory, run, ok }
}

test('adds, edits, moves and removes items like a person would', async (context) => {
  const { ok } = await setupCli(context)

  await ok('add', 'Plan for the week', '--date', '2026-09-28')
  await ok('add', 'Write the CLI', '--date', '2026-09-28', '--after', '1', '--level', '1', '--numbered')
  await ok('add', 'Test it', '--date', '2026-09-28', '--after', '2')
  await ok('add', 'Outline it', '--date', '2026-09-28', '--before', '2')
  let day = await ok('add', 'Gym', '--date', '2026-09-28')
  assert.equal(day.content, '- Plan for the week\n  1. Outline it\n  2. Write the CLI\n  3. Test it\n- Gym')
  assert.equal(day.title, 'Mon, September 28th, 2026')
  assert.deepEqual(
    day.items.map(({ n, level, list, number }) => [n, level, list, number]),
    [
      [1, 0, 'bullet', undefined],
      [2, 1, 'numbered', 1],
      [3, 1, 'numbered', 2],
      [4, 1, 'numbered', 3],
      [5, 0, 'bullet', undefined],
    ],
  )

  day = await ok('edit', '3', 'Write the companion CLI', '--date', '2026-09-28')
  assert.match(day.content, /2\. Write the companion CLI/)

  day = await ok('remove', '2', '--date', '2026-09-28')
  assert.equal(day.content, '- Plan for the week\n  1. Write the companion CLI\n  2. Test it\n- Gym')

  day = await ok('move', '4', '--date', '2026-09-28', '--before', '1')
  assert.equal(day.content, '- Gym\n- Plan for the week\n  1. Write the companion CLI\n  2. Test it')

  day = await ok('edit', '4', '--date', '2026-09-28', '--level', '0', '--bullet')
  assert.equal(day.content, '- Gym\n- Plan for the week\n  1. Write the companion CLI\n- Test it')

  const moved = await ok('move', '2', '--date', '2026-09-28', '--to', '2026-09-27')
  assert.equal(moved.from.content, '- Gym\n- Test it')
  assert.equal(moved.to.content, '- Plan for the week\n  1. Write the companion CLI')
})

test('accepts Markdown list markers in item text and option values', async (context) => {
  const { directory, ok } = await setupCli(context)

  await ok('add', '- Buy milk', '--date', '2026-09-24')
  await ok('add', '1. Call the bank', '--date', '2026-09-24')
  const day = await ok('write', '2026-09-24', '--append', '--content', '- Read later')
  assert.equal(day.content, '- Buy milk\n1. Call the bank\n- Read later')

  const piped = await new Promise((resolve, reject) => {
    const child = execFile(
      process.execPath,
      [CLI, '--data-dir', path.join(directory, 'data'), 'add', '-', '--date', '2026-09-24'],
      { env: { ...process.env, HOME: directory } },
      (error, stdout) => (error ? reject(error) : resolve(JSON.parse(stdout))),
    )
    child.stdin.end('Piped from another tool\n')
  })
  assert.equal(piped.items.at(-1).text, 'Piped from another tool')
})

test('writes many days at once and lists them', async (context) => {
  const { ok } = await setupCli(context)

  const written = await ok(
    'write',
    '--json',
    '--raw',
    '--content',
    JSON.stringify({
      '2026-09-25': '* Newsletter sent\n    - Deep\n1) One\n2) Two',
      '2026-09-26': ['- https://news.ycombinator.com/item?id=49854875'],
    }),
  )
  assert.deepEqual(written.days.map(({ date, items }) => [date, items]), [
    ['2026-09-25', 4],
    ['2026-09-26', 1],
  ])
  assert.equal((await ok('show', '2026-09-25')).content, '- Newsletter sent\n  - Deep\n1. One\n2. Two')

  const appended = await ok('write', '2026-09-26', '--append', '--content', '- Read later')
  assert.equal(appended.content, '- https://news.ycombinator.com/item?id=49854875\n- Read later')

  const { days } = await ok('days')
  assert.deepEqual(days.map(({ date, items }) => [date, items]), [
    ['2026-09-26', 2],
    ['2026-09-25', 4],
  ])

  const { results } = await ok('search', 'newsletter')
  assert.deepEqual(results.map(({ date, items }) => [date, items.map((item) => item.n)]), [['2026-09-25', [1]]])

  assert.deepEqual(await ok('clear', '2026-09-26'), { date: '2026-09-26', cleared: true })
  assert.deepEqual((await ok('days')).days.map(({ date }) => date), ['2026-09-25'])
})

test('adds images and keeps X posts as previews', async (context) => {
  const { directory, ok } = await setupCli(context)
  const image = path.join(directory, 'screenshot.png')
  await fs.writeFile(image, PIXEL_PNG)

  let day = await ok('image', image)
  assert.equal(day.date, todayKey())
  assert.equal(day.items[0].kind, 'image')
  assert.equal(day.items[0].image.alt, 'screenshot.png')

  day = await ok('add', 'https://x.com/flaviocopes/status/1715793063551832106')
  assert.equal(day.items[1].kind, 'post')
  assert.equal(day.items[1].text, 'https://x.com/flaviocopes/status/1715793063551832106')

  assert.deepEqual(await ok('title', 'https://x.com/flaviocopes/status/1715793063551832106'), {
    url: 'https://x.com/flaviocopes/status/1715793063551832106',
    title: null,
    text: 'https://x.com/flaviocopes/status/1715793063551832106',
    preview: 'x-post',
  })
  assert.equal((await ok('info')).images, 1)
})

test('explains mistakes with a JSON error and an exit code', async (context) => {
  const { directory, run } = await setupCli(context)
  await fs.writeFile(path.join(directory, 'fake.png'), 'not an image')

  const future = await run('add', 'Tomorrow', '--date', '2999-01-01')
  assert.equal(future.code, 1)
  assert.match(future.error, /in the future/)

  const missing = await run('edit', '3', 'Nope')
  assert.equal(missing.code, 1)
  assert.match(missing.error, /Item 3 doesn't exist/)

  assert.match((await run('add', 'Too deep', '--level', '2')).error, /deepest level allowed/)
  assert.match((await run('image', path.join(directory, 'fake.png'))).error, /isn't a PNG/)
  assert.equal((await run('frobnicate')).code, 2)
  assert.equal((await run('add', 'x', '--nope')).code, 2)
  assert.equal((await run('write', '2026-09-01', '--content', '  ')).code, 2)
  assert.equal((await run('reset')).code, 2)
})

test('backs up, resets and restores the notebook', async (context) => {
  const { directory, ok, run } = await setupCli(context)
  await ok('add', 'Keep me', '--date', '2026-09-20')

  const saved = await ok('backup')
  assert.equal(saved.days, 1)
  assert.match(saved.sha256, /^[a-f0-9]{64}$/)

  const reset = await ok('reset', '--yes')
  assert.equal(reset.days, 0)
  assert.match(reset.backup.path, /before-reset$/)
  await ok('add', 'Demo note', '--date', '2026-09-21')

  const restored = await ok('restore', saved.path, '--yes')
  assert.equal(restored.restored.days, 1)
  assert.match(restored.backup.path, /before-restore$/)
  assert.equal((await ok('show', '2026-09-20')).content, '- Keep me')
  assert.equal((await ok('show', '2026-09-21')).content, '')

  await fs.writeFile(path.join(directory, 'not-a-database.sqlite3'), 'nope')
  const broken = await run('restore', path.join(directory, 'not-a-database.sqlite3'), '--yes')
  assert.match(broken.error, /isn't a NoteRepo database/)
  assert.equal((await ok('show', '2026-09-20')).content, '- Keep me')
})
