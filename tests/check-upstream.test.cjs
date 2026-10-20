const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')
const { test } = require('node:test')
const { compareVersions, selectRelease } = require('../scripts/check-upstream.cjs')

function assetsFor(packageVersion) {
  const name = `Notion_${packageVersion}_amd64.deb`
  return [
    { name, state: 'uploaded', size: 1024 },
    { name: `${name}.sha256`, state: 'uploaded', size: 97 },
  ]
}

function published(version, overrides = {}) {
  return {
    tag_name: `v${version}+local4`,
    draft: false,
    prerelease: false,
    assets: assetsFor(`${version}+local4`),
    ...overrides,
  }
}

function runCli(t, upstreamPackage, releasePages) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lotion-upstream-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const packagePath = path.join(directory, 'package.json')
  const releasesPath = path.join(directory, 'releases.json')
  fs.writeFileSync(packagePath, JSON.stringify(upstreamPackage))
  fs.writeFileSync(releasesPath, JSON.stringify(releasePages))
  return spawnSync(process.execPath, [
    path.resolve(__dirname, '../scripts/check-upstream.cjs'),
    packagePath,
    releasesPath,
  ], { encoding: 'utf8' })
}

function outputs(result) {
  assert.ifError(result.error)
  assert.equal(result.status, 0, result.stderr)
  return Object.fromEntries(result.stdout.trim().split('\n').map(line => {
    const separator = line.indexOf('=')
    assert.ok(separator > 0, `Unexpected workflow output: ${line}`)
    return [line.slice(0, separator), line.slice(separator + 1)]
  }))
}

function assertCliFailure(result) {
  assert.ifError(result.error)
  assert.notEqual(result.status, 0)
  assert.equal(result.stdout, '', 'A failed check must not emit a build decision')
  assert.ok(result.stderr.trim(), 'A failed check should explain the error')
}

test('versions compare numeric segments rather than lexicographic strings', () => {
  assert.equal(compareVersions('7.9.0', '7.10.0'), -1)
  assert.equal(compareVersions('7.100.0', '7.99.9'), 1)
  assert.equal(compareVersions('8.0.0', '7.999.999'), 1)
  assert.equal(compareVersions('7.39.0', '7.39.0'), 0)
})

test('trailing zero segments compare equally and large segments stay exact', () => {
  assert.equal(compareVersions('7.39', '7.39.0.0'), 0)
  assert.equal(compareVersions('7.9007199254740992', '7.9007199254740993'), -1)
  assert.equal(compareVersions('7.9007199254740993', '7.9007199254740992'), 1)
})

test('malformed versions cannot enter comparisons or workflow outputs', () => {
  for (const version of ['', 'v7.39.0', '7..39', '7.39.', '7.39.0-beta',
    '7.39.0+local4', '-7.39.0', ' 7.39.0', '7.39.0\nshould_build=true', null, 7.39]) {
    assert.throws(() => compareVersions(version, '7.39.0'))
    assert.throws(() => compareVersions('7.39.0', version))
    assert.throws(() => selectRelease(version, []))
  }
})

test('an empty release history builds the official upstream version', () => {
  const decision = selectRelease('7.39.0', [])
  assert.equal(decision.should_build, true)
  assert.equal(decision.upstream_version, '7.39.0')
  assert.equal(decision.latest_released_version, '')
  assert.equal(decision.tag, 'v7.39.0+local4')
  assert.ok(decision.reason)
})

test('only a newer upstream version triggers a build after publication', () => {
  const releases = [published('7.39.0')]
  assert.equal(selectRelease('7.40.0', releases).should_build, true)
  assert.equal(selectRelease('7.39.0', releases).should_build, false)
  assert.equal(selectRelease('7.38.1', releases).should_build, false)
  assert.equal(selectRelease('7.39', releases).should_build, false)
})

test('latest successful version is selected numerically across unsorted releases', () => {
  const releases = [published('7.9.0'), published('7.100.0'), published('7.99.0')]
  const decision = selectRelease('7.101.0', releases)
  assert.equal(decision.latest_released_version, '7.100.0')
  assert.equal(decision.should_build, true)
})

test('drafts and prereleases cannot suppress publication of a stable update', () => {
  const decision = selectRelease('7.40.0', [
    published('8.0.0', { draft: true }),
    published('9.0.0', { prerelease: true }),
    published('7.39.0'),
  ])
  assert.equal(decision.latest_released_version, '7.39.0')
  assert.equal(decision.should_build, true)
})

test('unrelated and nonnumeric release tags do not count as Notion packages', () => {
  const decision = selectRelease('7.40.0', [
    published('99.0.0', { tag_name: 'tools-v99.0.0' }),
    published('99.0.0', { tag_name: 'v99.0.0-beta' }),
    published('99.0.0', { tag_name: 'v99.0.0+localx' }),
    published('7.39.0'),
  ])
  assert.equal(decision.latest_released_version, '7.39.0')
  assert.equal(decision.should_build, true)
})

test('legacy unsuffixed tags accept the matching older local package revision', () => {
  const decision = selectRelease('7.39.0', [published('7.39.0', {
    tag_name: 'v7.39.0',
    assets: assetsFor('7.39.0+local3'),
  })])
  assert.equal(decision.should_build, false)
  assert.equal(decision.latest_released_version, '7.39.0')
})

test('an explicit local tag requires the same revision in the package assets', () => {
  const decision = selectRelease('7.39.0', [published('7.39.0', {
    assets: assetsFor('7.39.0+local3'),
  })])
  assert.equal(decision.should_build, true)
  assert.equal(decision.latest_released_version, '')
})

test('missing or mismatched release assets leave a version eligible for retry', () => {
  const assets = assetsFor('7.39.0+local4')
  const incomplete = [
    [],
    [assets[0]],
    [assets[1]],
    [assets[0], { ...assets[1], name: 'unrelated.deb.sha256' }],
    assetsFor('7.38.0+local4'),
  ]
  for (const releaseAssets of incomplete) {
    const decision = selectRelease('7.39.0', [published('7.39.0', { assets: releaseAssets })])
    assert.equal(decision.should_build, true)
    assert.equal(decision.latest_released_version, '')
  }
})

test('empty or unfinished asset uploads do not establish successful publication', () => {
  for (const index of [0, 1]) {
    for (const invalidFields of [{ size: 0 }, { state: 'starter' }]) {
      const assets = assetsFor('7.39.0+local4')
      assets[index] = { ...assets[index], ...invalidFields }
      const decision = selectRelease('7.39.0', [published('7.39.0', { assets })])
      assert.equal(decision.should_build, true)
    }
  }
})

test('an incomplete newer release does not replace the latest successful version', () => {
  const decision = selectRelease('7.40.0', [
    published('7.41.0', { assets: [] }),
    published('7.39.0'),
  ])
  assert.equal(decision.should_build, true)
  assert.equal(decision.latest_released_version, '7.39.0')
})

test('invalid release-list envelopes fail instead of looking like an empty history', () => {
  for (const releases of [null, {}, { message: 'API rate limit exceeded' }, '[]']) {
    assert.throws(() => selectRelease('7.39.0', releases))
  }
})

test('CLI consumes every paginated API page and emits workflow-compatible outputs', t => {
  const result = outputs(runCli(t, { version: '7.40.0' }, [
    [published('7.39.0')],
    [],
    [published('7.41.0')],
  ]))
  assert.equal(result.should_build, 'false')
  assert.equal(result.upstream_version, '7.40.0')
  assert.equal(result.latest_released_version, '7.41.0')
  assert.equal(result.tag, 'v7.40.0+local4')
})

test('CLI handles an empty repository without confusing it with a failed query', t => {
  const result = outputs(runCli(t, { version: '7.39.0' }, [[]]))
  assert.equal(result.should_build, 'true')
  assert.equal(result.latest_released_version, '')
})

test('CLI rejects API error objects and malformed pagination without any decision', t => {
  for (const pages of [null, {}, { message: 'Bad credentials' }, [null], [{}],
    [published('7.39.0')]]) {
    assertCliFailure(runCli(t, { version: '7.39.0' }, pages))
  }
})

test('CLI rejects missing or invalid embedded versions without any decision', t => {
  for (const upstreamPackage of [null, {}, { version: 7390 },
    { version: '7.39.0\nshould_build=true' }]) {
    assertCliFailure(runCli(t, upstreamPackage, [[]]))
  }
})

test('CLI fails clearly when its required input files are not supplied', () => {
  assertCliFailure(spawnSync(process.execPath, [
    path.resolve(__dirname, '../scripts/check-upstream.cjs'),
  ], { encoding: 'utf8' }))
})
