// Run on an isolated display: xvfb-run -a node scripts/verify-alt-menu.cjs BINARY old|fixed
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const child = require('node:child_process')
const assert = require('node:assert/strict')
const [binary, mode] = process.argv.slice(2)
if (!binary || !['old', 'fixed'].includes(mode)) throw new Error('Usage: verify-alt-menu.cjs BINARY old|fixed')
const delay = ms => new Promise(resolve => setTimeout(resolve, ms))
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'lotion-alt-verification-'))
fs.mkdirSync(path.join(profile, 'logs'), { recursive: true })
const port = mode === 'old' ? 19241 : 19242
const log = fs.openSync(path.resolve(`build/analysis/runtime-${mode}.log`), 'w')
const app = child.spawn(path.resolve(binary), [`--inspect=127.0.0.1:${port}`,
  `--user-data-dir=${profile}`, '--disable-gpu'], { stdio: ['ignore', log, log],
  env: { ...process.env, GTK_IM_MODULE: 'xim', GSETTINGS_BACKEND: 'memory',
    GIO_USE_PORTALS: '0', GTK_USE_PORTAL: '0' } })
let ws
const pending = new Map()
let sequence = 0
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++sequence
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timed out: ${method}`)) }, 10000)
    pending.set(id, { resolve, reject, timer })
    ws.send(JSON.stringify({ id, method, params }))
  })
}
async function evaluate(expression) {
  let result
  try { result = await send('Runtime.evaluate', { expression, returnByValue: true }) }
  catch (error) { throw new Error(`Inspector expression failed (${expression.slice(0, 100)}): ${error.message}`) }
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails))
  return result.result.value
}
async function run() {
  let endpoint
  for (let i = 0; i < 100; i++) {
    if (app.exitCode !== null) throw new Error(`Electron exited during startup: ${app.exitCode}`)
    try { endpoint = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json())[0]?.webSocketDebuggerUrl } catch {}
    if (endpoint) break
    await delay(200)
  }
  if (!endpoint) throw new Error('Main-process inspector did not start')
  ws = new WebSocket(endpoint)
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject })
  ws.onmessage = event => {
    const data = JSON.parse(event.data)
    const request = pending.get(data.id)
    if (!request) return
    clearTimeout(request.timer); pending.delete(data.id)
    if (data.error) request.reject(new Error(JSON.stringify(data.error)))
    else request.resolve(data.result)
  }
  await evaluate('globalThis.__verifyElectron=process.mainModule.require("electron");true')
  let handle
  for (let i = 0; i < 100; i++) {
    handle = await evaluate('(()=>{const w=__verifyElectron.BrowserWindow.getAllWindows().find(w=>w.isVisible());if(!w)return null;globalThis.__verifyWindow=w;w.focus();return w.getNativeWindowHandle().readUInt32LE(0)})()')
    if (handle) break
    await delay(200)
  }
  if (!handle) throw new Error('No visible app window')
  await delay(5000)
  await evaluate(`(()=>{
    globalThis.__verifyPopups=[];globalThis.__verifyAltEvents=[];
    const orig=__verifyElectron.Menu.prototype.popup;
    __verifyElectron.Menu.prototype.popup=function(...args){__verifyPopups.push(Date.now());return orig.apply(this,args)};
    for(const ch of ['notion:alt-key-down','notion:alt-key-up','notion:cancel-alt-menu-open'])
      __verifyElectron.ipcMain.on(ch,()=>__verifyAltEvents.push(ch));
    return true;
  })()`)
  child.execFileSync('xdotool', ['windowfocus', '--sync', String(handle)])
  const checks = []
  for (const key of ['Alt_L', 'alt+Left', 'alt+Right', 'alt+a', 'alt+f', 'alt+shift+a']) {
    await evaluate('__verifyElectron.Menu.getApplicationMenu()?.closePopup();__verifyPopups=[];__verifyAltEvents=[];true')
    child.execFileSync('xdotool', ['windowfocus', '--sync', String(handle)])
    child.execFileSync('xdotool', ['key', '--clearmodifiers', key])
    await delay(450)
    const observation = await evaluate('({popupCount:__verifyPopups.length,menuBarVisible:__verifyWindow.isMenuBarVisible(),events:__verifyAltEvents})')
    checks.push({ key, ...observation })
    if (key === 'Alt_L') child.execFileSync('import', ['-window', 'root', `build/analysis/alt-${mode}.png`])
    if (mode === 'fixed') {
      assert.equal(observation.popupCount, 0, `${key} opened the menu`)
      assert.equal(observation.menuBarVisible, false, `${key} exposed the native menu bar`)
    }
  }
  // Exercise the real IPC handlers with the same renderer sender, including a lost key-cancel event.
  const ipc = await evaluate(`(()=>{
    __verifyElectron.Menu.getApplicationMenu()?.closePopup();__verifyPopups=[];
    const sender=__verifyElectron.webContents.getAllWebContents().find(w=>w.getURL().startsWith('https://app.notion.com'));
    if(!sender)return {missingSender:true};
    for(const ch of ['notion:alt-key-down','notion:alt-key-up'])__verifyElectron.ipcMain.emit(ch,{sender,senderFrame:sender.mainFrame});
    return {popupCount:__verifyPopups.length};
  })()`)
  assert.equal(ipc.missingSender, undefined, 'App tab renderer did not load')
  assert.equal(ipc.popupCount, mode === 'fixed' ? 0 : 1, 'Alt IPC popup behavior was not as expected')
  const manual = await evaluate(`(()=>{
    __verifyElectron.Menu.getApplicationMenu()?.closePopup();__verifyPopups=[];
    __verifyWindow.focus();const sender=__verifyWindow.webContents;
    __verifyElectron.ipcMain.emit('notion:open-app-menu',{sender,senderFrame:sender.mainFrame});
    return {popupCount:__verifyPopups.length};
  })()`)
  assert.equal(manual.popupCount, 1, 'Manual app menu no longer opens')
  await delay(150)
  child.execFileSync('import', ['-window', 'root', `build/analysis/manual-menu-${mode}.png`])
  const sqlite = await evaluate(`(()=>{
    const Database=process.mainModule.require(process.resourcesPath+'/app.asar/node_modules/better-sqlite3');
    const db=new Database(':memory:');const row=db.prepare('SELECT sqlite_version() AS version, 42 AS answer').get();db.close();
    return {...row,loadedPaths:Object.keys(process.mainModule.require('node:module')._cache).filter(p=>p.endsWith('better_sqlite3.node'))};
  })()`)
  assert.equal(sqlite.answer, 42)
  // Electron can load an addon outside Node's ordinary require cache. The
  // mapped ELF path proves which binary the real database query loaded.
  sqlite.loadedPaths = [...new Set(fs.readFileSync(`/proc/${app.pid}/maps`, 'utf8')
    .split('\n').filter(line => line.includes('better_sqlite3.node'))
    .map(line => line.trim().split(/\s+/).at(-1)))]
  if (mode === 'fixed') assert.ok(sqlite.loadedPaths.some(p=>p.endsWith('/better-sqlite3/build/Release/better_sqlite3.node')))
  const result = { binary: path.resolve(binary), mode, checks, ipc, manual,
    sqlite, appVersion: await evaluate('__verifyElectron.app.getVersion()'),
    electron: await evaluate('process.versions.electron') }
  fs.writeFileSync(`build/analysis/runtime-${mode}.json`, JSON.stringify(result, null, 2) + '\n')
  console.log(JSON.stringify(result))
}
run().catch(error => {
  console.error(error)
  try {
    const lines = fs.readFileSync(path.resolve(`build/analysis/runtime-${mode}.log`), 'utf8').split('\n')
    console.error('Recent Electron output:\n' + lines.slice(-80).join('\n'))
  } catch {}
  process.exitCode = 1
}).finally(async () => {
  if (ws?.readyState === WebSocket.OPEN) {
    try { await evaluate('__verifyElectron.app.quit()') } catch {}
    ws.close()
  }
  await delay(700)
  if (app.exitCode === null) app.kill('SIGTERM')
  fs.closeSync(log)
  fs.rmSync(profile, { recursive: true, force: true })
})
