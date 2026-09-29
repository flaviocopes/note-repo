const path = require('node:path')
const { app, BrowserWindow, ipcMain, nativeTheme, shell } = require('electron')
const { createAppServer } = require('./server.cjs')
const { NoteStore } = require('./store.cjs')

let mainWindow
let appServer
let noteStore
let changeWatcher
let pendingDay = ''

app.setName('NoteRepo')

const openDay = (date) => {
  if (!mainWindow || mainWindow.webContents.isLoading()) {
    pendingDay = date
    return
  }
  if (mainWindow.isMinimized()) mainWindow.restore()
  mainWindow.show()
  mainWindow.webContents.send('open-day', date)
}

app.on('open-url', (event, url) => {
  event.preventDefault()
  const match = url.match(/^noterepo:\/\/(?:day\/(\d{4}-\d{2}-\d{2})|today)\/?$/i)
  if (match) openDay(match[1] || 'today')
})

const watchOutsideChanges = () => {
  let dataVersion = noteStore.dataVersion()
  let versions = noteStore.versions()
  return setInterval(() => {
    const current = noteStore.dataVersion()
    if (current === dataVersion) return
    dataVersion = current
    const next = noteStore.versions()
    const dates = [...new Set([...versions.keys(), ...next.keys()])].filter(
      (date) => versions.get(date) !== next.get(date),
    )
    versions = next
    if (dates.length) mainWindow?.webContents.send('notes-changed', dates.sort())
  }, 500)
}

const windowBackground = () => (nativeTheme.shouldUseDarkColors ? '#14191b' : '#fafafa')

nativeTheme.on('updated', () => {
  if (mainWindow) mainWindow.setBackgroundColor(windowBackground())
})

const createWindow = async (appUrl) => {
  mainWindow = new BrowserWindow({
    width: 1240,
    height: 790,
    minWidth: 640,
    minHeight: 480,
    show: false,
    backgroundColor: windowBackground(),
    title: 'NoteRepo',
    titleBarStyle: 'hiddenInset',
    trafficLightPosition: { x: 16, y: 15 },
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      preload: path.join(__dirname, 'preload.cjs'),
    },
  })

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) shell.openExternal(url)
    return { action: 'deny' }
  })

  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith(appUrl)) event.preventDefault()
  })

  mainWindow.once('ready-to-show', () => mainWindow.show())
  mainWindow.on('closed', () => {
    mainWindow = null
  })

  await mainWindow.loadURL(appUrl)
  if (pendingDay) {
    openDay(pendingDay)
    pendingDay = ''
  }
}

ipcMain.handle('open-external', async (_event, url) => {
  if (!/^https?:\/\//i.test(url)) throw new TypeError('Only web links can be opened')
  await shell.openExternal(url)
})

app.whenReady().then(async () => {
  const dataDirectory = app.getPath('userData')
  noteStore = await new NoteStore(path.join(dataDirectory, 'notes.sqlite3'), {
    legacyPaths: [
      path.join(dataDirectory, 'notes.json'),
      path.join(app.getPath('appData'), 'noterepo', 'notes.json'),
    ],
  }).load()
  appServer = createAppServer({ distDir: path.join(__dirname, '..', 'dist'), store: noteStore })
  const appUrl = await appServer.listen()
  changeWatcher = watchOutsideChanges()
  await createWindow(appUrl)

  app.on('activate', async () => {
    if (BrowserWindow.getAllWindows().length === 0) await createWindow(appUrl)
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})

app.on('before-quit', () => {
  if (appServer) void appServer.close()
})

app.on('will-quit', () => {
  clearInterval(changeWatcher)
  if (noteStore) noteStore.close()
})
