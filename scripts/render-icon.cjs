// Rasterizes resources/AppIcon.svg with Electron's Chromium. Run with `npm run icon`.
const fs = require('node:fs')
const path = require('node:path')
const { app, BrowserWindow } = require('electron')

const root = path.join(__dirname, '..')
const outputs = [
  { file: path.join(root, 'resources', 'AppIcon.png'), size: 1024 },
  { file: path.join(root, 'public', 'app-icon.png'), size: 256 },
]

app.dock?.hide()

app.whenReady().then(async () => {
  const svg = fs.readFileSync(path.join(root, 'resources', 'AppIcon.svg'))
  const source = `data:image/svg+xml;base64,${svg.toString('base64')}`
  const window = new BrowserWindow({ show: false, webPreferences: { offscreen: true } })
  await window.loadURL('about:blank')

  for (const { file, size } of outputs) {
    const dataUrl = await window.webContents.executeJavaScript(`
      new Promise((resolve, reject) => {
        const image = new Image()
        image.onload = () => {
          const canvas = document.createElement('canvas')
          canvas.width = canvas.height = ${size}
          canvas.getContext('2d').drawImage(image, 0, 0, ${size}, ${size})
          resolve(canvas.toDataURL('image/png'))
        }
        image.onerror = () => reject(new Error('Could not load AppIcon.svg'))
        image.src = ${JSON.stringify(source)}
      })
    `)
    fs.writeFileSync(file, Buffer.from(dataUrl.split(',')[1], 'base64'))
    console.log(`${path.relative(root, file)} (${size}px)`)
  }

  app.quit()
})
