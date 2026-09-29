const path = require('node:path')
const { app, BrowserWindow, ipcMain, nativeTheme, shell } = require('electron')
const { createAppServer } = require('./server.cjs')
const { NoteStore } = require('./store.cjs')

let mainWindow
let appServer
let noteStore

app.setName('NoteRepo')

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
  if (noteStore) noteStore.close()
})
