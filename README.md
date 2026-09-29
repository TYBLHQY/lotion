# Notion for Linux (DEB)

This repository builds a Debian package from Notion's official Linux Flatpak release. It bundles the Flatpak application files and its runtime libraries under `/opt/Notion`, so installing and running the resulting `.deb` does not require Flatpak. The package is intended for personal use and is not affiliated with or endorsed by Notion.

## Build locally

The build downloads Notion's official `notion.flatpakref`, installs the signed app and its runtime into a temporary Flatpak user installation, then assembles a `.deb` in `dist/`.

Requirements are `flatpak`, `curl`, `dpkg-deb`, `desktop-file-validate`, and Python 3. On Debian, install the build tools with:

```sh
sudo apt install flatpak curl desktop-file-utils python3
```

Build the package with:

```sh
./build.sh
```

The package registers Notion's desktop entry and `notion://` URL handler. It attempts to copy the existing Flatpak profile from `~/.var/app/com.notion.app.desktop.notion/config/Notion` to `~/.config/Notion` the first time it launches. Since this is a normal Debian package, the app runs as your user without Flatpak's sandbox.

## Automated builds and releases

GitHub Actions builds and smoke-tests the `.deb` whenever `main` changes. A weekly scheduled run checks Notion's official Flatpak repository, and `workflow_dispatch` can run the same check on demand. A tested build is published as a GitHub Release only when its Flatpak commit has not already been released. The release includes the `.deb` and a SHA-256 checksum.

## Packaging notes

The `.flatpakref` points to Notion's signed application repository and the Flathub runtime repository; it does not contain application source code. This project extracts the installed payload and bundles the application and runtime files into the Debian package. The build records the upstream application version and Flatpak commit in `dist/build-metadata.json`; when Notion's Flatpak omits a version, it uses the latest known desktop version and a UTC build timestamp to keep Debian upgrades ordered.

The Notion application remains proprietary. The repository contains only packaging scripts and metadata; GitHub Actions fetches the official Linux payload during each build and attaches the resulting Debian package and checksum to the release.
