const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('desktop', {
  openExternal: (url) => ipcRenderer.invoke('open-external', url),
  onNotesChanged: (callback) => ipcRenderer.on('notes-changed', (_event, dates) => callback(dates)),
  onOpenDay: (callback) => ipcRenderer.on('open-day', (_event, date) => callback(date)),
})
