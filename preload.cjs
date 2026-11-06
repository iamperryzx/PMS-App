const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("pmsUpdater", {
  check: () => ipcRenderer.invoke("updates:check"),
  download: () => ipcRenderer.invoke("updates:download"),
  install: () => ipcRenderer.invoke("updates:install"),
  onStatus: callback => {
    const listener = (_event, status) => callback(status);
    ipcRenderer.on("updates:status", listener);
    return () => ipcRenderer.removeListener("updates:status", listener);
  }
});

contextBridge.exposeInMainWorld("pmsAuth", {
  onPasswordRecoveryLink: callback => {
    const listener = (_event, link) => callback(link);
    ipcRenderer.on("auth:password-recovery", listener);
    return () => ipcRenderer.removeListener("auth:password-recovery", listener);
  }
});
