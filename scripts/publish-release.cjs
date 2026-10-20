const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')
const { flattenReleasePages, isCompleteRelease } = require('./check-upstream.cjs')

function publishRelease({ repository, commit, tag, version, packagePath, notesPath }) {
  if (!repository || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    !/^[a-f0-9]{40}$/.test(commit ?? '') ||
    !/^[0-9]+(?:\.[0-9]+)*\+local4$/.test(version ?? '') ||
    ![`v${version}`, `v${version.replace(/\+local4$/, '')}`].includes(tag)) {
    throw new Error('Invalid release repository, commit, tag, or package version')
  }
  if (path.basename(packagePath) !== `Notion_${version}_amd64.deb`) {
    throw new Error('Package filename does not match the release version')
  }
  for (const file of [packagePath, `${packagePath}.sha256`, notesPath]) {
    const stat = fs.statSync(file)
    if (!stat.isFile() || stat.size === 0) {
      throw new Error(`Missing or empty release file: ${file}`)
    }
  }
  const gh = args => execFileSync('gh', args, {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'], maxBuffer: 32 * 1024 * 1024,
  })
  // A failed API request must stop publication, never imply the tag is absent.
  const releases = flattenReleasePages(JSON.parse(gh([
    'api', '--paginate', '--slurp', `repos/${repository}/releases?per_page=100`,
  ])))
  const existing = releases.find(release => release.tag_name === tag)
  if (existing && isCompleteRelease(existing)) {
    console.log(`Release ${tag} already has its DEB and checksum; leaving it unchanged.`)
    return
  }
  const details = [
    '--repo', repository, '--target', commit,
    '--title', `Notion ${version} for Linux`, '--notes-file', notesPath,
  ]
  if (existing) {
    // Interrupted uploads are retried as a draft with a consistent package pair.
    gh(['release', 'edit', tag, '--draft', '--prerelease=false', ...details])
  } else {
    gh(['release', 'create', tag, '--draft', ...details])
  }
  gh(['release', 'upload', tag, packagePath, `${packagePath}.sha256`,
    '--clobber', '--repo', repository])
  gh(['release', 'edit', tag, '--draft=false', '--prerelease=false', '--latest', '--repo', repository])
  console.log(`Published ${tag} with its DEB and SHA-256 checksum.`)
}

if (require.main === module) {
  try {
    const [tag, version, packagePath, notesPath, ...extra] = process.argv.slice(2)
    if (!tag || !version || !packagePath || !notesPath || extra.length) {
      throw new Error('Usage: node scripts/publish-release.cjs <tag> <version> <package.deb> <notes.md>')
    }
    publishRelease({ repository: process.env.GITHUB_REPOSITORY, commit: process.env.GITHUB_SHA,
      tag, version, packagePath, notesPath })
  } catch (error) {
    console.error(`Release publication failed: ${error.message}`)
    process.exitCode = 1
  }
}

module.exports = { publishRelease }
