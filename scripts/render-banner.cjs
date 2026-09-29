// Screenshots docs/banner.html in light and dark mode at 2x. Run with `npm run banner`.
const fs = require('node:fs')
const path = require('node:path')
const { app, BrowserWindow } = require('electron')

const root = path.join(__dirname, '..')
const width = 1280
const height = 560

app.dock?.hide()

app.whenReady().then(async () => {
  const window = new BrowserWindow({ width, height, show: false, webPreferences: { offscreen: true } })
  await window.loadURL('about:blank')
  const cdp = window.webContents.debugger
  cdp.attach()
  await cdp.sendCommand('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: false })
  await cdp.sendCommand('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } })

  for (const theme of ['light', 'dark']) {
    await cdp.sendCommand('Emulation.setEmulatedMedia', {
      features: [{ name: 'prefers-color-scheme', value: theme }],
    })
    await window.loadFile(path.join(root, 'docs', 'banner.html'))
    await window.webContents.executeJavaScript(
      'Promise.all([document.fonts.ready, ...[...document.images].map((image) => image.decode())])',
    )
    const { data } = await cdp.sendCommand('Page.captureScreenshot', {
      format: 'png',
      clip: { x: 0, y: 0, width, height, scale: 1 },
    })
    const file = path.join(root, 'docs', `banner-${theme}.png`)
    fs.writeFileSync(file, Buffer.from(data, 'base64'))
    console.log(path.relative(root, file))
  }

  app.quit()
})
