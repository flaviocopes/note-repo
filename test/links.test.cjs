const assert = require('node:assert/strict')
const test = require('node:test')
const { fetchLinkTitle, linkText, redditLink } = require('../electron/links.cjs')

const POST = 'https://www.reddit.com/r/programming/comments/1d50fcu/htmx_simplicity_in_an_age_of_complicated_solutions/'

const stubFetch = (context, respond) => {
  const original = globalThis.fetch
  const requests = []
  globalThis.fetch = async (url, options) => {
    requests.push(String(url))
    return respond(String(url), options)
  }
  context.after(() => {
    globalThis.fetch = original
  })
  return requests
}

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

test('recognizes Reddit posts, comments and share links', () => {
  assert.deepEqual(redditLink(POST), { subreddit: 'programming', post: '1d50fcu', comment: null })
  assert.deepEqual(redditLink(`${POST}l6jz9qa/?context=3`), {
    subreddit: 'programming',
    post: '1d50fcu',
    comment: 'l6jz9qa',
  })
  assert.deepEqual(redditLink('https://old.reddit.com/r/programming/comments/1d50fcu/comment/l6jz9qa/'), {
    subreddit: 'programming',
    post: '1d50fcu',
    comment: 'l6jz9qa',
  })
  assert.deepEqual(redditLink('https://reddit.com/user/flaviocopes/comments/1d50fcu/a_post/'), {
    subreddit: null,
    post: '1d50fcu',
    comment: null,
  })
  assert.deepEqual(redditLink('https://redd.it/1d50fcu'), { post: '1d50fcu', comment: null })
  assert.deepEqual(redditLink('https://www.reddit.com/r/programming/s/AbCdEf1234'), { share: true })
  assert.equal(redditLink('https://www.reddit.com/r/programming/'), null)
  assert.equal(redditLink('https://notreddit.com/r/programming/comments/1d50fcu/'), null)
})

test('uses the Reddit post title, and labels comments', async (context) => {
  const requests = stubFetch(context, () => json({ title: 'htmx: Simplicity in an Age of Complicated Solutions' }))

  assert.equal(await fetchLinkTitle(POST), 'htmx: Simplicity in an Age of Complicated Solutions')
  assert.equal(
    await fetchLinkTitle(`${POST}l6jz9qa/`),
    'Comment to htmx: Simplicity in an Age of Complicated Solutions',
  )
  assert.equal(await fetchLinkTitle('https://redd.it/1d50fcu'), 'htmx: Simplicity in an Age of Complicated Solutions')
  assert.equal(
    new URL(requests[1]).searchParams.get('url'),
    'https://www.reddit.com/r/programming/comments/1d50fcu/',
  )
  assert.equal(
    new URL(requests[2]).searchParams.get('url'),
    'https://www.reddit.com/r/reddit/comments/1d50fcu/',
  )
})

test('follows Reddit share links to the post they point to', async (context) => {
  stubFetch(context, (url) => {
    if (url.includes('/s/')) {
      return new Response(null, { status: 301, headers: { Location: `${POST}l6jz9qa/?share_id=abc` } })
    }
    return json({ title: 'htmx: Simplicity in an Age of Complicated Solutions' })
  })

  assert.equal(
    await fetchLinkTitle('https://www.reddit.com/r/programming/s/AbCdEf1234'),
    'Comment to htmx: Simplicity in an Age of Complicated Solutions',
  )
})

test('leaves Reddit links without a title when Reddit does not answer', async (context) => {
  stubFetch(context, () => json({ message: 'Not Found' }, 404))
  assert.equal(await fetchLinkTitle(POST), null)
})

test('formats a titled link the way the editor saves it', () => {
  assert.equal(
    linkText('https://en.wikipedia.org/wiki/Rust_(programming_language)', 'Rust [language]'),
    '[Rust (language)](https://en.wikipedia.org/wiki/Rust_%28programming_language%29) (en.wikipedia.org)',
  )
  assert.equal(linkText('https://www.reddit.com/r/x/comments/1/', 'Post'), '[Post](https://www.reddit.com/r/x/comments/1/) (reddit.com)')
})
