const assert = require('node:assert/strict')
const test = require('node:test')
const {
  describeOutline,
  inputEntries,
  mergeContent,
  parseOutline,
  serializeOutline,
} = require('../electron/outline.cjs')

test('keeps untouched lines exactly as they were saved', () => {
  const content = 'Built NoteRepo today.\n- Groceries\n\t- Apples\n1. One\n2. Two'
  assert.equal(serializeOutline(parseOutline(content)), content)
  assert.deepEqual(parseOutline(''), [])
})

test('renumbers numbered lists after an item is added', () => {
  const entries = parseOutline('- Plan\n  1. Write\n  2. Test')
  entries.splice(1, 0, { depth: 1, ordered: true, start: 1, body: 'Outline', raw: '', dirty: true })
  assert.equal(serializeOutline(entries), '- Plan\n  1. Outline\n  2. Write\n  3. Test')
})

test('describes each item with its number, level, list and kind', () => {
  const image = 'a'.repeat(64)
  const items = describeOutline(
    parseOutline(
      [
        '- Plan',
        '  1. Read [Write-Ahead Logging](https://sqlite.org/wal.html) (sqlite.org)',
        '',
        `- ![Screenshot](noterepo:image:${image})`,
        '- https://x.com/flaviocopes/status/1715793063551832106',
      ].join('\n'),
    ),
  )

  assert.deepEqual(
    items.map(({ n, level, list, number, kind }) => ({ n, level, list, number, kind })),
    [
      { n: 1, level: 0, list: 'bullet', number: undefined, kind: 'text' },
      { n: 2, level: 1, list: 'numbered', number: 1, kind: 'link' },
      { n: 3, level: 0, list: 'bullet', number: undefined, kind: 'image' },
      { n: 4, level: 0, list: 'bullet', number: undefined, kind: 'post' },
    ],
  )
  assert.deepEqual(items[1].links, [{ title: 'Write-Ahead Logging', url: 'https://sqlite.org/wal.html' }])
  assert.deepEqual(items[2].image, { id: image, alt: 'Screenshot' })
  assert.equal(items[3].post.user, 'flaviocopes')
})

test('turns Markdown written by agents into NoteRepo lines', () => {
  const entries = inputEntries('* One\r\n\n    + Deep\u200b  \n1) First\n2. Second\n-\n\tTabbed')
  assert.deepEqual(
    entries.map(({ depth, ordered, body }) => [depth, ordered, body]),
    [
      [0, false, 'One'],
      [2, false, 'Deep'],
      [0, true, 'First'],
      [0, true, 'Second'],
      [1, false, 'Tabbed'],
    ],
  )
})

test('merges an outside change into unsaved edits', () => {
  const base = '- A\n- B'
  assert.equal(mergeContent(base, '- A\n- B\n- Mine', '- A\n- B\n- Theirs'), '- A\n- B\n- Mine\n- Theirs')
  assert.equal(mergeContent(base, '- A edited\n- B', '- A\n- B changed'), '- A edited\n- B changed')
  assert.equal(mergeContent(base, '- A\n- B\n- Mine', '- B'), '- B\n- Mine')
  assert.equal(mergeContent(base, '- A mine\n- B', '- A theirs\n- B'), '- A mine\n- A theirs\n- B')
  assert.equal(mergeContent(base, base, '- Theirs'), '- Theirs')
  assert.equal(mergeContent(base, '- Mine', base), '- Mine')
  assert.equal(mergeContent('', '- Mine', '- Theirs'), '- Mine\n- Theirs')
})
