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
and sign-in state. The generated package gets a `+local4` Debian version suffix
so it upgrades the previous local build.

The Linux repack disables the app-menu popup triggered by Alt key IPC events.
Other Alt shortcuts remain available, and clicking the Notion menu button still
opens File/Edit/View/History/Window/Help. The compatibility patches locate AST
structures instead of relying on minified local variable names. Each target
must match exactly once, otherwise the build stops.

The launcher uses XIM for GTK input-method integration. This is a per-Notion
setting; check text input in the repackaged app on your desktop before relying on
it as a replacement for the distro's default GTK input method.

The local Windows installer belongs at
`build/inputs/notion-windows-installer.exe`. Build outputs and extracted
proprietary client files stay under `build/` and `dist/`; neither directory is
tracked by Git. Published releases contain the generated DEB and its checksum;
the original installer and extracted source files are not committed. Notion's
installer and application remain subject to their own terms.

## Requirements

- Linux x86_64
- Node.js 24.19+ and npm
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
NOTION_INSTALLER_PATH=/path/to/NotionSetup.exe NOTION_EXPECTED_VERSION=7.37.1 ./build.sh
```

The script writes the Debian package under `dist/`. It deliberately does not
install the package. Review the build output and install it yourself if you
want to try it. The package uses a `+local4` version suffix, so apt can upgrade
the previous local build without `--reinstall`.

Build tools are pinned by `package-lock.json`. The package includes
`/usr/share/doc/notion/build-manifest.json` with EXE/ASAR hashes, versions,
applied patch ranges and hashes, source file hashes, and an inventory of the
actual packaged native addons. SQLite is rebuilt for the extracted Electron
version; its alternative platform prebuilds and test extension are excluded.
Windows/macOS-specific upstream addons remain in their guarded platform paths.

## Verify the Alt menu fix

The build runs the real upstream Alt IPC callbacks through Linux, Windows, and
macOS regression cases before patching. To exercise an assembled app with actual
keyboard input, use an isolated display and a fresh disposable profile:

```sh
xvfb-run -a node scripts/verify-alt-menu.cjs build/deb-staging/opt/Notion/notion fixed
```

This checks Alt and representative combinations, lost-cancel IPC behavior,
manual menu opening, and a real SQLite query under Electron. It enables a local
main-process inspector for that disposable test app, never for the ordinary
desktop launcher. Results go to ignored `build/analysis/` files.

REA can supplement artifact analysis without changing agent configuration:

```sh
npx --yes rea-agents@6.4.0 analyze-javascript-application /path/to/app.asar --json
```

For the 7.37.1 official EXE, REA reports native-addon integrity contradictions
between the original ASAR metadata and its unpacked files. A diagnostic run with
`--integrity-policy record-and-continue` retains these as untrusted observations.
Its application graph also leaves bundled custom IPC unresolved, so runtime
verification is required to establish the Alt behavior.

The package registers Notion's `notion://` URL handler with the Linux desktop,
so the browser can return a completed sign-in to the app. If another application
owns that handler, select Notion as the default with
`xdg-mime default local.personal.notion.desktop x-scheme-handler/notion`.

## Publish releases with GitHub Actions

The workflow checks the official Windows installer every Monday and can also
be started manually from the Actions tab. It reads the version from the
installer and only builds when that version is newer than the latest release.

You can also publish a specific version by pushing a matching tag, for example:

```sh
git tag v7.37.1+local4
git push origin v7.37.1+local4
```

The workflow builds the package on Ubuntu, checks that the package matches the
upstream version, and runs the Alt-menu keyboard and SQLite checks under Xvfb.
After these pass it publishes the DEB and SHA-256 checksum as a GitHub Release.
Verification logs, screenshots, and the build manifest are saved as an Actions
artifact. Scheduled releases use the `+local4` suffix as well. The installer and
generated package are not committed to Git.

## What this experiment can and cannot establish

If the repacked client starts, it should use the client code and SQLite-backed
record cache extracted from the official app. This may improve repeat page
navigation. It does not make Notion's servers local: initial sign-in, uncached
pages, and fresh data still require network access. Compare a cold start and a
repeat visit in the same workspace before drawing conclusions.

The upstream repack recipe and Notion releases may change. The script checks
for the expected installer archive and patch targets, and stops if those
assumptions no longer hold.
