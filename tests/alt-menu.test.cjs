const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const { test } = require('node:test')
const { patchBundle, collectHandlers } = require('../scripts/patch-notion.cjs')

const sourcePath = process.env.NOTION_TEST_BUNDLE
if (!sourcePath) throw new Error('Set NOTION_TEST_BUNDLE to the unmodified upstream main bundle')
const original = fs.readFileSync(sourcePath, 'utf8')
const { patched, report } = patchBundle(original)

function runAltSequence(source, platform) {
  const actions = []
  class WindowController {
    setShouldShowAppMenuFromAltKey(value) { actions.push(['armed', value]) }
    toggleAppMenuPopup() { actions.push(['popup']) }
  }
  const controller = new WindowController()
  for (const callback of Object.values(collectHandlers(source))) {
    const appSymbol = callback.match(/([\w$]+)\.appController/)[1]
    const windowSymbol = callback.match(/([\w$]+)\.WindowController/)[1]
    const context = { process: { platform },
      [appSymbol]: { appController: { getWindowControllerForWebContents: () => controller } },
      [windowSymbol]: { WindowController } }
    vm.runInNewContext(`(${callback})`, context)({ sender: {} })
  }
  return actions
}

test('reproduce upstream Linux Alt popup using the real IPC callbacks', () => {
  assert.deepEqual(runAltSequence(original, 'linux'), [['armed', true], ['popup'], ['armed', false]])
})
test('Linux Alt down/up never arm or popup the menu after patching', () => {
  assert.deepEqual(runAltSequence(patched, 'linux'), [])
})
test('Windows retains its Alt menu and macOS retains its existing behavior', () => {
  assert.deepEqual(runAltSequence(patched, 'win32'), runAltSequence(original, 'win32'))
  assert.deepEqual(runAltSequence(patched, 'darwin'), [])
})
test('the mouse menu popup implementation is retained byte for byte', () => {
  const extract = s => s.match(/\.showAppMenu=function\(\)\{.*?(?=,\w+\.closeAppMenu=function)/s)?.[0]
  assert.ok(extract(original))
  assert.equal(extract(original), extract(patched))
})
test('unknown upstream handlers fail instead of silently omitting the Alt fix', () => {
  assert.throws(() => patchBundle(original.replace('notion:alt-key-up', 'notion:unknown-key-up')), /expected one IPC handler/)
  assert.throws(() => patchBundle(patched), /expected one structural target/)
  assert.equal(report.changes.length, 6)
})
