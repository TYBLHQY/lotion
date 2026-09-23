# Notion Linux Repack (personal experiment)

This project explores whether repackaging Notion's official Windows desktop
client for Linux preserves its local record cache and improves repeat page
loads. It is an unofficial, personal-use experiment and is not affiliated with
or endorsed by Notion.

## Approach

The build extracts the official Windows installer, rebuilds `better-sqlite3`
for Linux, and keeps Notion's existing Linux platform paths intact. It patches
the tray menu to use Electron's Linux context-menu API, adds the missing tray
icon, starts Electron with GTK's XIM input method to avoid loading the GTK3
Fcitx module implicated in theme-switch crashes, and asks `electron-builder` to
create a Debian package. The launcher preserves the normal desktop config path
and leaves `GTK_THEME` unset, so default browser associations remain available
and Notion can follow the system theme. It pins Notion's user data to the usual
`$XDG_CONFIG_HOME/Notion` path, preserving the existing profile, local database,
and sign-in state. The generated package gets a `+local2` Debian version suffix
so it upgrades the previous local build.

The launcher uses XIM for GTK input-method integration. This is a per-Notion
setting; check text input in the repackaged app on your desktop before relying on
it as a replacement for the distro's default GTK input method.

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
want to try it. The package uses a `+local2` version suffix, so apt can upgrade
the previous local build without `--reinstall`.

## Publish releases with GitHub Actions

The workflow checks the official Windows installer every Monday and can also
be started manually from the Actions tab. It reads the version from the
installer and only builds when that version is newer than the latest release.

You can also publish a specific version by pushing a matching tag, for example:

```sh
git tag v7.35.1
git push origin v7.35.1
```

The workflow builds the package on Ubuntu, checks that the package matches the
upstream version, creates a SHA-256 checksum, and publishes both files as a
GitHub Release. The installer and generated package are not committed to Git.

## Build a GTK4 test package

Electron 43.6.0 links GTK at runtime, but the stock Notion binary in this
repack links GTK3 directly. The `Build GTK4 Notion test package` workflow
rebuilds Electron 43.6.0 against Chromium's GTK4 support, packages the current
Notion installer with that Electron distribution, and uploads the `.deb` as a
temporary Actions artifact. It does not publish a release.

Chromium's source and build output need substantially more disk than a standard
GitHub-hosted runner provides. The workflow therefore requires a dedicated
Linux x86_64 self-hosted runner labeled `notion-gtk4`, with at least 300 GB of
free disk, 16 GB RAM, GTK4 development files, and the Chromium build
dependencies preinstalled. It runs only when manually dispatched; it is not
used by pull-request or release workflows. Each Actions job has a six-hour
limit, so rerunning after a timeout resumes from the persistent source/build
directory on that runner.

To build, open **Actions → Build GTK4 Notion test package → Run workflow**.
Download the `notion-gtk4-deb` artifact from the completed run. Test system
theme switching and browser sign-in before replacing the existing local
package.

## What this experiment can and cannot establish

If the repacked client starts, it should use the client code and SQLite-backed
record cache extracted from the official app. This may improve repeat page
navigation. It does not make Notion's servers local: initial sign-in, uncached
pages, and fresh data still require network access. Compare a cold start and a
repeat visit in the same workspace before drawing conclusions.

The upstream repack recipe and Notion releases may change. The script checks
for the expected installer archive and patch targets, and stops if those
assumptions no longer hold.
