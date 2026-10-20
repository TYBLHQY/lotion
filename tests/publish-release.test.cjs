const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const { test } = require('node:test')

const version = '7.40.0+local4'
const tag = `v${version}`
const packageName = `Notion_${version}_amd64.deb`

function release(overrides = {}) {
  return {
    tag_name: tag,
    draft: false,
    prerelease: false,
    assets: [
      { name: packageName, state: 'uploaded', size: 1024 },
      { name: `${packageName}.sha256`, state: 'uploaded', size: 97 },
    ],
    ...overrides,
  }
}

function fixture(t, pages = [[]]) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lotion-publish-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const bin = path.join(directory, 'bin')
  fs.mkdirSync(bin)
  const logPath = path.join(directory, 'gh-calls.jsonl')
  const releasesPath = path.join(directory, 'releases.json')
  const packagePath = path.join(directory, packageName)
  const notesPath = path.join(directory, 'notes.md')
  fs.writeFileSync(releasesPath, JSON.stringify(pages))
  fs.writeFileSync(packagePath, 'local test package\n')
  fs.writeFileSync(`${packagePath}.sha256`, `${'0'.repeat(64)}  ${packageName}\n`)
  fs.writeFileSync(notesPath, 'Local test release notes\n')
  fs.writeFileSync(path.join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('node:fs')
const args = process.argv.slice(2)
fs.appendFileSync(process.env.LOTION_TEST_GH_LOG, JSON.stringify(args) + '\\n')
if (args[0] === 'api') {
  if (process.env.LOTION_TEST_API_ERROR === '1') {
    console.error('simulated GitHub API failure')
    process.exit(1)
  }
  process.stdout.write(fs.readFileSync(process.env.LOTION_TEST_RELEASES_FILE, 'utf8'))
} else if (args[0] === 'release') {
  if (args[1] === 'upload' && process.env.LOTION_TEST_UPLOAD_ERROR === '1') {
    console.error('simulated incomplete asset upload')
    process.exit(1)
  }
} else {
  console.error('unexpected gh command')
  process.exit(1)
}
`, { mode: 0o755 })

  return {
    packagePath,
    notesPath,
    releasesPath,
    run({ args = [tag, version, packagePath, notesPath], env = {} } = {}) {
      const result = spawnSync(process.execPath, [
        path.resolve(__dirname, '../scripts/publish-release.cjs'), ...args,
      ], {
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${bin}${path.delimiter}${process.env.PATH}`,
          GITHUB_REPOSITORY: 'owner/lotion',
          GITHUB_SHA: 'a'.repeat(40),
          LOTION_TEST_GH_LOG: logPath,
          LOTION_TEST_RELEASES_FILE: releasesPath,
          ...env,
        },
      })
      assert.ifError(result.error)
      const calls = fs.existsSync(logPath)
        ? fs.readFileSync(logPath, 'utf8').trim().split('\n').map(line => JSON.parse(line))
        : []
      return { ...result, calls }
    },
  }
}

function commands(result) {
  return result.calls.map(args => args.slice(0, 2).join(' '))
}

function assertFailed(result) {
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /Release publication failed:/)
}

test('new release is created as a draft, receives both assets, and is then published', t => {
  const files = fixture(t)
  const result = files.run()
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(commands(result), ['api --paginate', 'release create', 'release upload', 'release edit'])
  assert.ok(result.calls[0].includes('--slurp'))
  assert.ok(result.calls[1].includes('--draft'))
  assert.ok(result.calls[1].includes('a'.repeat(40)))
  assert.ok(result.calls[2].includes(files.packagePath))
  assert.ok(result.calls[2].includes(`${files.packagePath}.sha256`))
  assert.ok(result.calls[2].includes('--clobber'))
  assert.ok(result.calls[3].includes('--draft=false'))
  assert.ok(result.calls[3].includes('--latest'))
})

test('existing drafts and incomplete public releases are reused during a retry', t => {
  for (const existing of [release({ draft: true }), release({ assets: [] })]) {
    const result = fixture(t, [[existing]]).run()
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(commands(result), ['api --paginate', 'release edit', 'release upload', 'release edit'])
    assert.ok(result.calls[1].includes('--draft'))
    assert.ok(result.calls[1].includes('--prerelease=false'))
    assert.ok(result.calls[3].includes('--draft=false'))
  }
})

test('a complete published release is left unchanged even on a later API page', t => {
  const result = fixture(t, [[], [release()]]).run()
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(commands(result), ['api --paginate'])
  assert.match(result.stdout, /already has its DEB and checksum/)
})

test('an existing release missing its checksum is retried with the complete package pair', t => {
  const existing = release()
  existing.assets.pop()
  const result = fixture(t, [[existing]]).run()
  assert.equal(result.status, 0, result.stderr)
  assert.deepEqual(commands(result), ['api --paginate', 'release edit', 'release upload', 'release edit'])
})

test('GitHub API errors cannot cause a release creation or edit', t => {
  const result = fixture(t).run({ env: { LOTION_TEST_API_ERROR: '1' } })
  assertFailed(result)
  assert.deepEqual(commands(result), ['api --paginate'])
})

test('malformed API responses stop publication before any mutation', t => {
  for (const pages of [{ message: 'Bad credentials' }, [null], [[{ tag_name: tag }]]]) {
    const result = fixture(t, pages).run()
    assertFailed(result)
    assert.deepEqual(commands(result), ['api --paginate'])
  }
  const files = fixture(t)
  fs.writeFileSync(files.releasesPath, '{invalid JSON')
  const result = files.run()
  assertFailed(result)
  assert.deepEqual(commands(result), ['api --paginate'])
})

test('an asset upload failure leaves the draft unpublished', t => {
  const result = fixture(t).run({ env: { LOTION_TEST_UPLOAD_ERROR: '1' } })
  assertFailed(result)
  assert.deepEqual(commands(result), ['api --paginate', 'release create', 'release upload'])
  assert.ok(result.calls[1].includes('--draft'))
})

test('legacy unsuffixed tags remain supported for a manually selected version', t => {
  const files = fixture(t)
  const result = files.run({ args: ['v7.40.0', version, files.packagePath, files.notesPath] })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.calls[1][2], 'v7.40.0')
  assert.equal(result.calls[3][2], 'v7.40.0')
})

test('invalid release identifiers fail validation before invoking GitHub', t => {
  for (const invalidTag of ['v7.41.0+local4', 'v7.40.0+local3', '--help', `${tag}\nextra`]) {
    const files = fixture(t)
    const result = files.run({ args: [invalidTag, version, files.packagePath, files.notesPath] })
    assertFailed(result)
    assert.deepEqual(result.calls, [])
  }
  for (const env of [{ GITHUB_REPOSITORY: 'owner/lotion/extra' }, { GITHUB_SHA: 'main' }]) {
    const result = fixture(t).run({ env })
    assertFailed(result)
    assert.deepEqual(result.calls, [])
  }
})

test('missing, empty, and mismatched local release files prevent GitHub mutations', t => {
  for (const fileKind of ['package', 'checksum', 'notes']) {
    const files = fixture(t)
    const file = fileKind === 'package' ? files.packagePath
      : fileKind === 'checksum' ? `${files.packagePath}.sha256` : files.notesPath
    fs.unlinkSync(file)
    const missing = files.run()
    assertFailed(missing)
    assert.deepEqual(missing.calls, [])
    fs.writeFileSync(file, '')
    const empty = files.run()
    assertFailed(empty)
    assert.deepEqual(empty.calls, [])
  }
  const files = fixture(t)
  const mismatched = files.run({ args: [tag, version, `${files.packagePath}.other`, files.notesPath] })
  assertFailed(mismatched)
  assert.deepEqual(mismatched.calls, [])
})
