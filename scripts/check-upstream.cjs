const fs = require('node:fs')

const VERSION = /^[0-9]+(?:\.[0-9]+)*$/
const RELEASE_TAG = /^v([0-9]+(?:\.[0-9]+)*)(\+local[0-9]+)?$/

function versionParts(version) {
  if (typeof version !== 'string' || !VERSION.test(version)) {
    throw new Error(`Unexpected Notion version: ${JSON.stringify(version)}`)
  }
  return version.split('.').map(part => BigInt(part))
}

function compareVersions(left, right) {
  const a = versionParts(left)
  const b = versionParts(right)
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const difference = (a[index] ?? 0n) - (b[index] ?? 0n)
    if (difference !== 0n) return difference < 0n ? -1 : 1
  }
  return 0
}

function validateReleases(releases) {
  if (!Array.isArray(releases) || releases.some(release =>
    !release || typeof release.tag_name !== 'string' ||
    typeof release.draft !== 'boolean' || typeof release.prerelease !== 'boolean' ||
    !Array.isArray(release.assets))) {
    throw new Error('Invalid GitHub releases response; refusing to assume an empty release history')
  }
  return releases
}

function flattenReleasePages(pages) {
  if (!Array.isArray(pages) || pages.some(page => !Array.isArray(page))) {
    throw new Error('Expected paginated GitHub releases arrays from gh api --paginate --slurp')
  }
  return validateReleases(pages.flat())
}

function isCompleteRelease(release) {
  const tag = release.tag_name.match(RELEASE_TAG)
  if (!tag || release.draft || release.prerelease) return false
  const uploaded = release.assets.filter(asset =>
    asset && asset.state === 'uploaded' && Number.isFinite(asset.size) && asset.size > 0)
  return uploaded.some(asset => {
    const packageName = typeof asset.name === 'string' &&
      asset.name.match(/^Notion_([0-9]+(?:\.[0-9]+)*)(\+local[0-9]+)?_amd64\.deb$/)
    if (!packageName || packageName[1] !== tag[1] ||
      (tag[2] && packageName[2] !== tag[2])) return false
    return uploaded.some(checksum => checksum.name === `${asset.name}.sha256`)
  })
}

function selectRelease(upstreamVersion, releases) {
  versionParts(upstreamVersion)
  validateReleases(releases)
  let latest = ''
  for (const release of releases) {
    if (!isCompleteRelease(release)) continue
    const version = release.tag_name.match(RELEASE_TAG)[1]
    if (!latest || compareVersions(version, latest) > 0) latest = version
  }
  const shouldBuild = !latest || compareVersions(upstreamVersion, latest) > 0
  return {
    upstream_version: upstreamVersion,
    latest_released_version: latest,
    tag: `v${upstreamVersion}+local4`,
    should_build: shouldBuild,
    reason: shouldBuild
      ? `Notion ${upstreamVersion} needs a complete published Linux package.`
      : `Notion ${upstreamVersion} is not newer than the latest complete release ${latest}; skipping build.`,
  }
}

if (require.main === module) {
  try {
    const [packagePath, releasesPath, ...extra] = process.argv.slice(2)
    if (!packagePath || !releasesPath || extra.length) {
      throw new Error('Usage: node scripts/check-upstream.cjs <package.json> <releases-pages.json>')
    }
    const upstreamPackage = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
    const releases = flattenReleasePages(JSON.parse(fs.readFileSync(releasesPath, 'utf8')))
    const result = selectRelease(upstreamPackage?.version, releases)
    // Emit outputs only after every input has been validated successfully.
    process.stdout.write(Object.entries(result).map(([key, value]) => `${key}=${value}\n`).join(''))
  } catch (error) {
    console.error(`Upstream check failed: ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = { compareVersions, selectRelease, isCompleteRelease, flattenReleasePages }
