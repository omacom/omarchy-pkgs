// The meeting nub starts a drag on every mouse down via electron-click-drag-plugin.
// That addon calls XQueryPointer. On Wayland the native handle is not an X
// window, Xlib's default error handler calls exit(), and Granola dies mid-call,
// taking the unsaved transcript with it. A click is a mouse down, so both
// click and drag hit this path.
//
// Loaded with electron --require, before the app. Never block the main thread
// on a Hyprland round-trip: Hyprland can be waiting to write a Wayland event
// back to this process, and a synchronous hyprctl deadlocks it.

'use strict';

const fs = require('fs');
const net = require('net');
const path = require('path');
const { app, BrowserWindow, ipcMain, screen } = require('electron');
const Module = require('module');

const BTN_LEFT = 0x110;
const EV_KEY = 1;
const INPUT_EVENT_SIZE = 24;

let addonPatched = false;
let session = null;
let timer = null;
let inputFds = [];

function hyprSocketPath() {
  const sig = process.env.HYPRLAND_INSTANCE_SIGNATURE;
  const runtime = process.env.XDG_RUNTIME_DIR;
  if (!sig || !runtime) return null;
  const path = `${runtime}/hypr/${sig}/.socket.sock`;
  return fs.existsSync(path) ? path : null;
}

function hyprRequest(command) {
  const path = hyprSocketPath();
  if (!path) return Promise.reject(new Error('no hyprland socket'));
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(path);
    let buf = '';
    const timerId = setTimeout(() => {
      sock.destroy();
      reject(new Error(`hyprland timed out: ${command.slice(0, 80)}`));
    }, 400);
    sock.on('connect', () => sock.end(command));
    sock.on('data', (chunk) => {
      buf += chunk;
    });
    sock.on('end', () => {
      clearTimeout(timerId);
      resolve(buf);
    });
    sock.on('error', (err) => {
      clearTimeout(timerId);
      reject(err);
    });
  });
}

function parsePair(text) {
  const match = String(text).match(/(-?\d+)\s*,\s*(-?\d+)/);
  if (!match) return null;
  return { x: Number(match[1]), y: Number(match[2]) };
}

function pointOf(value) {
  if (Array.isArray(value) && value.length >= 2) return { x: Number(value[0]), y: Number(value[1]) };
  if (value && typeof value.x === 'number' && typeof value.y === 'number') return { x: value.x, y: value.y };
  return null;
}

function electronCursor() {
  try {
    const point = screen.getCursorScreenPoint();
    if (!point || (point.x === 0 && point.y === 0)) return null;
    return point;
  } catch {
    return null;
  }
}

function nubWindow() {
  return BrowserWindow.getAllWindows().find((win) => !win.isDestroyed() && win.getTitle() === 'Nub') || null;
}

function validAddress(address) {
  return typeof address === 'string' && /^0x[0-9a-fA-F]+$/.test(address);
}

async function findHyprNub() {
  const clients = JSON.parse(await hyprRequest('j/clients'));
  const pid = process.pid;
  return clients.find((client) => client && client.pid === pid && client.title === 'Nub' && validAddress(client.address)) || null;
}

function stopInputWatch() {
  for (const fd of inputFds) {
    try {
      fs.closeSync(fd);
    } catch {
      // already closed
    }
  }
  inputFds = [];
}

function openButtonWatch() {
  let dir;
  try {
    dir = fs.readdirSync('/dev/input');
  } catch {
    return;
  }
  for (const name of dir) {
    if (!/^event\d+$/.test(name)) continue;
    try {
      inputFds.push(fs.openSync(`/dev/input/${name}`, fs.constants.O_RDONLY | fs.constants.O_NONBLOCK));
    } catch {
      // Some event nodes are root-only. The ones we can read are enough.
    }
  }
}

function buttonReleased() {
  const buf = Buffer.alloc(INPUT_EVENT_SIZE * 64);
  for (const fd of inputFds) {
    let n = 0;
    try {
      n = fs.readSync(fd, buf, 0, buf.length, null);
    } catch (err) {
      if (err.code !== 'EAGAIN' && err.code !== 'EWOULDBLOCK') continue;
    }
    for (let offset = 0; offset + INPUT_EVENT_SIZE <= n; offset += INPUT_EVENT_SIZE) {
      const type = buf.readUInt16LE(offset + 16);
      const code = buf.readUInt16LE(offset + 18);
      const value = buf.readInt32LE(offset + 20);
      if (type === EV_KEY && code === BTN_LEFT && value === 0) return true;
    }
  }
  return false;
}

function rememberInElectron(win) {
  if (!session || session.x == null || !win || win.isDestroyed()) return;
  const bounds = win.getBounds();
  try {
    win.setBounds({ x: session.x, y: session.y, width: bounds.width, height: bounds.height });
  } catch {
    // Wayland ignores programmatic moves. The compositor position is already updated.
  }
}

function finishDrag() {
  const win = session && session.win;
  if (timer) clearInterval(timer);
  timer = null;
  stopInputWatch();
  rememberInElectron(win);
  session = null;
}

async function moveHypr(address, x, y) {
  const reply = await hyprRequest(
    `dispatch hl.dsp.window.move({ x = ${x}, y = ${y}, window = "address:${address}" })`,
  );
  if (!reply.startsWith('ok')) throw new Error(reply.trim() || 'hyprland move failed');
}

async function prepareHyprWindow(client) {
  const at = pointOf(client.at);
  const size = pointOf(client.size);
  if (!at) throw new Error('nub has no hyprland position');
  if (client.floating === false && size) {
    await hyprRequest(`dispatch hl.dsp.window.float({ window = "address:${client.address}" })`);
    await hyprRequest(
      `dispatch hl.dsp.window.resize({ x = ${Math.round(size.x)}, y = ${Math.round(size.y)}, window = "address:${client.address}" })`,
    );
  }
  return at;
}

async function tick() {
  const current = session;
  if (!current || current.busy || !current.win || current.win.isDestroyed()) return;
  if (buttonReleased()) {
    finishDrag();
    return;
  }
  current.busy = true;
  try {
    if (current.mode === 'hypr') {
      const cursor = parsePair(await hyprRequest('cursorpos'));
      if (!session || session !== current || !cursor) return;
      const x = Math.round(cursor.x - current.dx);
      const y = Math.round(cursor.y - current.dy);
      if (x !== current.x || y !== current.y) {
        await moveHypr(current.address, x, y);
        if (session === current) {
          current.x = x;
          current.y = y;
        }
      }
      return;
    }
    const cursor = electronCursor();
    if (!session || session !== current || !cursor || current.win.isDestroyed()) return;
    const x = Math.round(cursor.x - current.dx);
    const y = Math.round(cursor.y - current.dy);
    if (x === current.x && y === current.y) return;
    if (current.mode === 'sway') {
      const { spawn } = require('child_process');
      spawn('swaymsg', ['--', '[title="^Nub$"]', 'move', 'position', String(x), String(y)], {
        stdio: 'ignore',
      }).unref();
    } else {
      const bounds = current.win.getBounds();
      current.win.setBounds({ x, y, width: bounds.width, height: bounds.height });
    }
    current.x = x;
    current.y = y;
  } catch (err) {
    if (session === current && !current.warned) {
      current.warned = true;
      console.error('nub drag failed', err);
    }
  } finally {
    if (session === current) current.busy = false;
  }
}

async function beginNubDrag() {
  const win = nubWindow();
  if (!win) return;
  finishDrag();
  const next = { win, busy: false, warned: false, x: null, y: null };
  session = next;
  try {
    if (hyprSocketPath()) {
      const client = await findHyprNub();
      if (!session || session !== next) return;
      if (!client) throw new Error('nub window is not in hyprland');
      const at = await prepareHyprWindow(client);
      const cursor = parsePair(await hyprRequest('cursorpos'));
      if (!session || session !== next || !cursor) return;
      next.mode = 'hypr';
      next.address = client.address;
      next.dx = cursor.x - at.x;
      next.dy = cursor.y - at.y;
      next.x = Math.round(at.x);
      next.y = Math.round(at.y);
    } else {
      const cursor = electronCursor();
      const bounds = win.getBounds();
      if (!cursor) return;
      next.mode = process.env.SWAYSOCK ? 'sway' : 'bounds';
      next.dx = cursor.x - bounds.x;
      next.dy = cursor.y - bounds.y;
      next.x = bounds.x;
      next.y = bounds.y;
    }
  } catch (err) {
    console.error('nub drag failed', err);
    if (session === next) session = null;
    return;
  }
  if (session !== next) return;
  openButtonWatch();
  timer = setInterval(() => {
    tick();
  }, 20);
}

function patchDragExports(exported) {
  if (!exported || typeof exported.startDrag !== 'function' || exported.startDrag.__granolaSafe) return;
  const safe = function granolaSafeStartDrag() {
    beginNubDrag();
  };
  safe.__granolaSafe = true;
  try {
    exported.startDrag = safe;
    addonPatched = true;
  } catch (err) {
    console.error('nub drag: could not replace startDrag', err);
  }
}

const originalRequire = Module.prototype.require;
Module.prototype.require = function (id) {
  const exported = originalRequire.apply(this, arguments);
  if (id === 'electron-click-drag-plugin' || (typeof id === 'string' && id.includes('electron-click-drag-plugin'))) {
    patchDragExports(exported);
    if (exported && exported.default) patchDragExports(exported.default);
  }
  return exported;
};

const originalIpcOn = ipcMain.on;
ipcMain.on = function (channel, listener) {
  if (process.platform === 'linux' && channel === 'nub:start-drag') {
    return originalIpcOn.call(ipcMain, channel, (event, ...args) => {
      if (!addonPatched) {
        beginNubDrag();
        return;
      }
      return listener(event, ...args);
    });
  }
  if (process.platform === 'linux' && channel === 'nub:end-drag') {
    return originalIpcOn.call(ipcMain, channel, (event, ...args) => {
      finishDrag();
      return listener(event, ...args);
    });
  }
  return originalIpcOn.call(ipcMain, channel, listener);
};

app.on('will-quit', finishDrag);

// The tray always loads resources/icons/iconTemplate.png. That file is the
// macOS menu-bar template, a different glyph from the app icon. A system
// electron binary launched with the asar also resolves that path under the
// asar filename, so the file is missing and the bar draws a fallback.
function markIconPath() {
  const home = process.env.HOME || '';
  const candidates = [
    path.join(__dirname, 'granola-icon.png'),
    path.join(__dirname, 'resources', 'icons', 'mac-icon.png'),
    path.join(home, '.local/share/icons/hicolor/256x256/apps/granola.png'),
    path.join(home, '.local/share/pixmaps/granola.png'),
    '/usr/share/pixmaps/granola.png',
  ];
  for (const candidate of candidates) {
    try {
      if (fs.statSync(candidate).size > 1000) return candidate;
    } catch {
      // try the next candidate
    }
  }
  return null;
}

function installTrayIcon() {
  const { nativeImage } = require('electron');
  if (!nativeImage || nativeImage.createFromPath.__granolaMark) return;
  const orig = nativeImage.createFromPath;
  let mark = null;
  function createFromPath(iconPath) {
    if (String(iconPath || '').endsWith('iconTemplate.png')) {
      if (!mark) {
        const markPath = markIconPath();
        if (markPath) mark = orig.call(nativeImage, markPath);
      }
      if (mark && !mark.isEmpty()) return mark;
    }
    return orig.call(nativeImage, iconPath);
  }
  createFromPath.__granolaMark = true;
  nativeImage.createFromPath = createFromPath;
}

// Granola shows the main window from its own ready-to-show listener. Attach
// after that listener and hide on the next turn, once the window has mapped.
function hideMainWindowOnLaunch() {
  app.on('browser-window-created', (_event, win) => {
    let title = '';
    try {
      title = win.getTitle();
    } catch {
      return;
    }
    // The page renames this to "Granola" before ready-to-show. Match the
    // constructor title, then hide after Granola's own show().
    if (title !== 'Main window') return;
    process.nextTick(() => {
      if (win.isDestroyed()) return;
      win.once('ready-to-show', () => {
        setImmediate(() => {
          if (!win.isDestroyed()) win.hide();
        });
      });
    });
  });
}

installTrayIcon();
hideMainWindowOnLaunch();
