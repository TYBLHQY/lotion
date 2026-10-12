const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')
const child = require('node:child_process')
const asar = require('@electron/asar')
const [project, app, installer, stage, upstreamAsar] = process.argv.slice(2)
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const appPackage = JSON.parse(fs.readFileSync(path.join(app, 'package.json')))
const patches = JSON.parse(fs.readFileSync(path.join(project, 'build/patch-report.json')))
const archive = path.join(stage, 'opt/Notion/resources/app.asar')
const nodes = []
for (const entry of asar.listPackage(archive)) {
    const file = entry.replace(/^\//, '')
    if (file.endsWith('.node')) {
      const data = asar.extractFile(archive, file)
      const magic = data.subarray(0, 4).toString('hex')
      const format = magic === '7f454c46' ? 'ELF' : magic.startsWith('4d5a') ? 'PE' :
        ['cffaedfe', 'feedfacf', 'cafebabe'].includes(magic) ? 'Mach-O' : 'unknown'
      nodes.push({ path: file, format, unpacked: Boolean(asar.statFile(archive, file).unpacked),
        sha256: crypto.createHash('sha256').update(data).digest('hex') })
    }
}
const sqlite = nodes.find(n => n.path === 'node_modules/better-sqlite3/build/Release/better_sqlite3.node')
if (sqlite?.format !== 'ELF') throw new Error('SQLite rebuild is not a Linux ELF module')
const main = path.join(app, '.webpack/main/index.js')
if (sha(main) !== patches.patched_sha256) throw new Error('Patched main bundle does not match patch report')
const packagedMainHash = crypto.createHash('sha256').update(asar.extractFile(archive, '.webpack/main/index.js')).digest('hex')
if (packagedMainHash !== patches.patched_sha256) throw new Error('Packaged ASAR lost the patched main bundle')
const packagedVersion = JSON.parse(asar.extractFile(archive, 'package.json').toString()).version
if (packagedVersion !== appPackage.version) throw new Error('Packaged app version does not match the extracted EXE')
const manifest = {
  schema_version: 1,
  package_version: `${appPackage.version}+local4`,
  upstream_version: appPackage.version,
  electron_version: appPackage.devDependencies.electron,
  sqlite_version: JSON.parse(fs.readFileSync(path.join(app, 'node_modules/better-sqlite3/package.json'))).version,
  installer: { filename: path.basename(installer), sha256: sha(installer) },
  upstream_asar_sha256: sha(upstreamAsar),
  packaged_asar_sha256: sha(path.join(stage, 'opt/Notion/resources/app.asar')),
  source_commit: child.execFileSync('git', ['rev-parse', 'HEAD'], { cwd: project, encoding: 'utf8' }).trim(),
  source_files: Object.fromEntries(['build.sh', 'launch-notion.sh', 'scripts/patch-notion.cjs',
    'scripts/write-build-manifest.cjs', 'package-lock.json'].map(file => [file, sha(path.join(project, file))])),
  node_version: process.version,
  patches,
  native_addons: nodes
}
const docs = path.join(stage, 'usr/share/doc/notion')
fs.mkdirSync(docs, { recursive: true })
fs.writeFileSync(path.join(docs, 'build-manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
console.log(`Recorded installer, ASAR, ${patches.changes.length} patches and ${nodes.length} native addon digests`)
