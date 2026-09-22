# Notion Linux Repack (personal experiment)

This project explores whether repackaging Notion's official Windows desktop
client for Linux preserves its local record cache and improves repeat page
loads. It is an unofficial, personal-use experiment and is not affiliated with
or endorsed by Notion.

## Approach

The build extracts the official Windows installer, rebuilds `better-sqlite3`
for Linux, and keeps Notion's existing Linux platform paths intact. It patches
the tray menu to use Electron's Linux context-menu API, adds the missing tray
icon, and asks `electron-builder` to create a Debian package. The generated
package gets a `+local1` Debian version suffix so it upgrades a package built
from the same upstream release.

The local Windows installer belongs at
`build/inputs/notion-windows-installer.exe`. Build outputs and extracted
proprietary client files stay under `build/` and `dist/`; neither directory is
tracked by Git. Do not publish or redistribute those files. Notion's installer
and application remain subject to their own terms.

## Requirements

- Linux x86_64
- Node.js and npm
- Network access to Notion, npm, and Electron's header distribution
- 7-Zip (`7z`)
- `file`, to reject a Windows-native SQLite module after the rebuild
- `dpkg-deb` (for Debian package output)
- A C/C++ build toolchain and Python, required when rebuilding the native
  SQLite module

## Build

```sh
./build.sh
```

The build uses the project-local installer automatically. If you want to use a
different installer, set `NOTION_INSTALLER_PATH`:

```sh
NOTION_INSTALLER_PATH=/path/to/NotionSetup.exe ./build.sh
```

The script writes the Debian package under `dist/`. It deliberately does not
install the package. Review the build output and install it yourself if you
want to try it. The package uses a `+local1` version suffix, so apt can upgrade
an earlier local build without `--reinstall`.

## Publish a private release with GitHub Actions

The workflow checks the official Windows installer every Monday and can also
be started manually from the Actions tab. It reads the version from the
installer and only builds when that version is newer than the latest private
release.

You can also publish a specific version by pushing a matching tag, for example:

```sh
git tag v7.35.1
git push origin v7.35.1
```

The workflow builds the package on Ubuntu, checks that the package matches the
upstream version, creates a SHA-256 checksum, and publishes both files as a
private GitHub Release. It stops if the repository is not private. The installer
and generated package are not committed to Git.

## What this experiment can and cannot establish

If the repacked client starts, it should use the client code and SQLite-backed
record cache extracted from the official app. This may improve repeat page
navigation. It does not make Notion's servers local: initial sign-in, uncached
pages, and fresh data still require network access. Compare a cold start and a
repeat visit in the same workspace before drawing conclusions.

The upstream repack recipe and Notion releases may change. The script checks
for the expected installer archive and patch targets, and stops if those
assumptions no longer hold.
