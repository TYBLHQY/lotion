const fs = require('node:fs')
const crypto = require('node:crypto')
const acorn = require('acorn')
const walk = require('acorn-walk')

const hash = value => crypto.createHash('sha256').update(value).digest('hex')
const parse = source => acorn.parse(source, { ecmaVersion: 'latest', sourceType: 'script' })
const property = (node, name) => node?.type === 'MemberExpression' &&
  !node.computed && node.property.name === name
const isPlatform = node => property(node, 'platform') && node.object.name === 'process'
const isPlatformTest = (node, value, operator = '===') =>
  node.type === 'BinaryExpression' && node.operator === operator &&
  ((isPlatform(node.left) && node.right.value === value) ||
   (isPlatform(node.right) && node.left.value === value))

function patchBundle(source) {
  const ast = parse(source)
  const changes = []
  const selectOne = (name, candidates, replacement) => {
    if (candidates.length !== 1) {
      throw new Error(`${name}: expected one structural target, found ${candidates.length}`)
    }
    const node = candidates[0]
    changes.push({ name, start: node.start, end: node.end,
      before: source.slice(node.start, node.end),
      after: typeof replacement === 'function' ? replacement(node) : replacement })
  }
  const collect = (root, type, predicate) => {
    const nodes = []
    walk.simple(root, { [type](node) { if (predicate(node)) nodes.push(node) } })
    return nodes
  }
  const text = node => source.slice(node.start, node.end)

  const trayMethods = collect(ast, 'MethodDefinition', node =>
    node.key.name === 'getIsEnabled' && text(node).includes('isMenuBarIconEnabled'))
  const trayTests = trayMethods.flatMap(node => collect(node, 'BinaryExpression', n => isPlatformTest(n, 'win32')))
  selectOne('linux-tray-enabled', trayTests, '"linux"===process.platform')

  const preferences = collect(ast, 'ConditionalExpression', node =>
    isPlatformTest(node.test, 'win32') && node.consequent.type === 'CallExpression' &&
    node.consequent.callee.type === 'FunctionExpression' &&
    ['isOpenAtLoginEnabled', 'isQuickSearchEnabled', 'isHideLastWindowOnCloseEnabled']
      .every(key => text(node.consequent).includes(key)))
  selectOne('linux-launch-preferences', preferences.map(node => node.test), '"linux"===process.platform')

  const troubleshooting = collect(ast, 'ConditionalExpression', node =>
    isPlatformTest(node.test, 'win32') && node.consequent.type === 'ArrayExpression' &&
    text(node.consequent).includes('.buildTroubleshootingMenu'))
  selectOne('linux-troubleshooting-menu', troubleshooting.map(node => node.test), '"linux"===process.platform')

  const rightClicks = collect(ast, 'CallExpression', node =>
    property(node.callee, 'on') && property(node.callee.object, 'tray') &&
    node.callee.object.object.type === 'ThisExpression' &&
    node.arguments[0]?.value === 'right-click' &&
    node.arguments[1]?.type === 'ArrowFunctionExpression' &&
    property(node.arguments[1].body.callee, 'onRightClick'))
  selectOne('linux-native-tray-menu', rightClicks, node =>
    `("linux"===process.platform?this.tray.setContextMenu(this.trayMenu):${text(node)})`)

  for (const phase of ['down', 'up']) {
    const channel = `notion:alt-key-${phase}`
    const handlers = collect(ast, 'CallExpression', node =>
      property(node.callee, 'addListener') && node.arguments[0]?.value === channel &&
      node.arguments[1]?.type === 'ArrowFunctionExpression')
    if (handlers.length !== 1) throw new Error(`${channel}: expected one IPC handler, found ${handlers.length}`)
    const guards = collect(handlers[0].arguments[1], 'BinaryExpression', node =>
      isPlatformTest(node, 'darwin', '!=='))
    selectOne(`alt-menu-windows-only-${phase}`, guards, '"win32"===process.platform')
  }

  changes.sort((a, b) => a.start - b.start)
  for (let i = 1; i < changes.length; i++) {
    if (changes[i].start < changes[i - 1].end) throw new Error('Patch targets overlap')
  }
  let patched = source
  for (const change of [...changes].reverse()) {
    patched = patched.slice(0, change.start) + change.after + patched.slice(change.end)
  }
  parse(patched)
  return { patched, report: {
    schema_version: 1, original_sha256: hash(source), patched_sha256: hash(patched),
    changes: changes.map(({ name, start, end, before, after }) => ({
      name, start, end, before_sha256: hash(before), after_sha256: hash(after)
    }))
  } }
}

module.exports = { patchBundle, parse, collectHandlers }

function collectHandlers(source) {
  const handlers = {}
  walk.simple(parse(source), { CallExpression(node) {
    if (property(node.callee, 'addListener') &&
        ['notion:alt-key-down', 'notion:alt-key-up'].includes(node.arguments[0]?.value)) {
      handlers[node.arguments[0].value] = source.slice(node.arguments[1].start, node.arguments[1].end)
    }
  } })
  return handlers
}

if (require.main === module) {
  const [bundlePath, reportPath] = process.argv.slice(2)
  if (!bundlePath || !reportPath) throw new Error('Usage: patch-notion.cjs BUNDLE REPORT')
  const { patched, report } = patchBundle(fs.readFileSync(bundlePath, 'utf8'))
  fs.writeFileSync(bundlePath, patched)
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n')
  console.log(`Applied ${report.changes.length} verified Linux patches; ${report.patched_sha256}`)
}
