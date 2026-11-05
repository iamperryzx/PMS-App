const { app, BrowserWindow, dialog, ipcMain, protocol } = require("electron");
const { readFile } = require("node:fs/promises");
const path = require("node:path");
const { autoUpdater } = require("electron-updater");

let mainWindow;

function sendUpdateStatus(status) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send("updates:status", status);
  }
}

function formatReleaseNotes(releaseNotes) {
  if (typeof releaseNotes === "string") return releaseNotes;
  if (Array.isArray(releaseNotes)) {
    return releaseNotes
      .map(note => typeof note === "string" ? note : note?.note)
      .filter(note => typeof note === "string" && note.trim())
      .join("\n");
  }
  return "";
}

protocol.registerSchemesAsPrivileged([
  {
    scheme: "pms",
    privileges: {
      standard: true,
      secure: true,
      supportFetchAPI: true
    }
  }
]);

const gotSingleInstanceLock = app.requestSingleInstanceLock();

if (!gotSingleInstanceLock) {
  app.quit();
} else {
  app.setPath("userData", path.join(app.getPath("appData"), "PMS Enterprise"));
  autoUpdater.autoDownload = false;
  autoUpdater.autoInstallOnAppQuit = true;
  autoUpdater.allowPrerelease = false;

  autoUpdater.on("checking-for-update", () => sendUpdateStatus({ type: "checking" }));
  autoUpdater.on("update-available", info => sendUpdateStatus({
    type: "available",
    version: info.version,
    releaseNotes: formatReleaseNotes(info.releaseNotes)
  }));
  autoUpdater.on("update-not-available", info => sendUpdateStatus({
    type: "not-available",
    version: info.version
  }));
  autoUpdater.on("download-progress", progress => sendUpdateStatus({
    type: "progress",
    percent: Math.round(progress.percent)
  }));
  autoUpdater.on("update-downloaded", info => sendUpdateStatus({
    type: "downloaded",
    version: info.version
  }));
  autoUpdater.on("error", error => {
    console.error("PMS update check failed:", error);
    sendUpdateStatus({ type: "error", message: error.message });
  });

  app.whenReady().then(async () => {
    ipcMain.handle("updates:check", async () => {
      if (!app.isPackaged) return { development: true };
      try {
        await autoUpdater.checkForUpdates();
        return { started: true };
      } catch (error) {
        console.error("Could not check for PMS updates:", error);
        return { error: error.message };
      }
    });

    ipcMain.handle("updates:download", async () => {
      if (!app.isPackaged) return { error: "Cập nhật chỉ khả dụng trong bản đã cài đặt." };
      try {
        await autoUpdater.downloadUpdate();
        return { started: true };
      } catch (error) {
        console.error("Could not download PMS update:", error);
        return { error: error.message };
      }
    });

    ipcMain.handle("updates:install", () => {
      if (!app.isPackaged) return false;
      autoUpdater.quitAndInstall();
      return true;
    });

    protocol.handle("pms", async (request) => {
      const url = new URL(request.url);
      if (url.hostname !== "app" || url.pathname !== "/index.html") {
        return new Response("Not found", { status: 404 });
      }

      try {
        const html = await readFile(path.join(__dirname, "index.html"));
        return new Response(html, {
          headers: {
            "content-type": "text/html; charset=utf-8",
            "content-security-policy": "default-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'"
          }
        });
      } catch (error) {
        console.error("Could not load the PMS interface:", error);
        return new Response("Could not load the PMS interface.", { status: 500 });
      }
    });

    mainWindow = new BrowserWindow({
      width: 1440,
      height: 900,
      minWidth: 1024,
      minHeight: 700,
      backgroundColor: "#f4f2ed",
      autoHideMenuBar: true,
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
        webSecurity: true,
        preload: path.join(__dirname, "preload.cjs")
      }
    });

    mainWindow.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    mainWindow.webContents.on("will-navigate", (event, url) => {
      if (!url.startsWith("pms://app/")) event.preventDefault();
    });

    try {
      await mainWindow.loadURL("pms://app/index.html");
      if (app.isPackaged) {
        const startupCheck = setTimeout(() => {
          autoUpdater.checkForUpdates().catch(error => {
            console.error("Automatic PMS update check failed:", error);
          });
        }, 12000);
        startupCheck.unref();
        const periodicCheck = setInterval(() => {
          autoUpdater.checkForUpdates().catch(error => {
            console.error("Periodic PMS update check failed:", error);
          });
        }, 4 * 60 * 60 * 1000);
        periodicCheck.unref();
      }
    } catch (error) {
      console.error("Could not open the PMS window:", error);
      dialog.showErrorBox("Không thể mở PMS", "Không tải được giao diện ứng dụng. Vui lòng kiểm tra bộ cài.");
      app.quit();
    }
  });

  app.on("window-all-closed", () => {
    if (process.platform !== "darwin") app.quit();
  });

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) app.quit();
  });
}
