#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
EXTRACT_DIR="$BUILD_DIR/extracted"
APP_DIR="$BUILD_DIR/app"
INSTALLER="$BUILD_DIR/notion-windows-installer.exe"
LOCAL_INSTALLER="$BUILD_DIR/inputs/notion-windows-installer.exe"

for required_command in 7z node npm file dpkg-deb; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$required_command" >&2
    exit 1
  fi
done

# Pin the parser, packager, ASAR utility and native rebuild tool with npm's lockfile.
npm ci --prefix "$PROJECT_ROOT" --ignore-scripts --no-audit --no-fund

rm -rf "$EXTRACT_DIR" "$BUILD_DIR/payload" "$APP_DIR"
mkdir -p "$EXTRACT_DIR"

if [[ -n "${NOTION_INSTALLER_PATH:-}" ]]; then
  if [[ ! -f "$NOTION_INSTALLER_PATH" ]]; then
    printf 'NOTION_INSTALLER_PATH does not point to a file.\n' >&2
    exit 1
  fi
  cp -- "$NOTION_INSTALLER_PATH" "$INSTALLER"
elif [[ -f "$LOCAL_INSTALLER" ]]; then
  printf 'Using the project-local Notion installer: %s\n' "$LOCAL_INSTALLER"
  cp -- "$LOCAL_INSTALLER" "$INSTALLER"
else
  if ! command -v curl >/dev/null 2>&1; then
    printf 'Missing required command for downloading the installer: curl\n' >&2
    exit 1
  fi
  printf 'Downloading the official Notion Windows installer...\n'
  curl --fail --location --retry 3 \
    'https://www.notion.so/desktop/windows/download' \
    --output "$INSTALLER"
fi

printf 'Extracting the Electron payload...\n'
7z x -y "$INSTALLER" '$PLUGINSDIR/app-64.7z' "-o$EXTRACT_DIR" >/dev/null
PAYLOAD_ARCHIVE="$(find "$EXTRACT_DIR" -type f -name 'app-64.7z' -print -quit)"
if [[ -z "$PAYLOAD_ARCHIVE" ]]; then
  printf 'Could not find $PLUGINSDIR/app-64.7z in the installer.\n' >&2
  exit 1
fi

mkdir -p "$BUILD_DIR/payload"
7z x -y "$PAYLOAD_ARCHIVE" \
  'resources/app.asar' \
  'resources/app.asar.unpacked/*' \
  'resources/icon-production.png' \
  "-o$BUILD_DIR/payload" >/dev/null
ASAR_FILE="$BUILD_DIR/payload/resources/app.asar"
if [[ ! -f "$ASAR_FILE" ]]; then
  printf 'Could not find resources/app.asar in the Windows payload.\n' >&2
  exit 1
fi

"$PROJECT_ROOT/node_modules/.bin/asar" extract "$ASAR_FILE" "$APP_DIR"
APP_VERSION="$(node -p "require('$APP_DIR/package.json').version")"
if [[ -n "${NOTION_EXPECTED_VERSION:-}" && "$APP_VERSION" != "$NOTION_EXPECTED_VERSION" ]]; then
  printf 'Expected Notion %s but extracted %s.\n' "$NOTION_EXPECTED_VERSION" "$APP_VERSION" >&2
  exit 1
fi

ELECTRON_VERSION="$(node -p "require('$APP_DIR/package.json').devDependencies.electron")"
if [[ -z "$ELECTRON_VERSION" || "$ELECTRON_VERSION" == "undefined" ]]; then
  printf 'Could not determine the Electron version from the extracted app.\n' >&2
  exit 1
fi

SQLITE_MODULE="$APP_DIR/node_modules/better-sqlite3"
if [[ ! -d "$SQLITE_MODULE" ]]; then
  printf 'The extracted app does not contain better-sqlite3 at the expected path.\n' >&2
  exit 1
fi

SQLITE_VERSION="$(node -p "require('$SQLITE_MODULE/package.json').version")"
SQLITE_SOURCE_DIR="$BUILD_DIR/better-sqlite3-source"
printf 'Fetching better-sqlite3 %s sources for Electron %s...\n' "$SQLITE_VERSION" "$ELECTRON_VERSION"
npm pack "better-sqlite3@$SQLITE_VERSION" --pack-destination "$BUILD_DIR"
SQLITE_TARBALL="$(find "$BUILD_DIR" -maxdepth 1 -type f -name "better-sqlite3-$SQLITE_VERSION.tgz" -print -quit)"
if [[ -z "$SQLITE_TARBALL" ]]; then
  printf 'Could not download the matching better-sqlite3 source package.\n' >&2
  exit 1
fi
rm -rf "$SQLITE_SOURCE_DIR"
mkdir -p "$SQLITE_SOURCE_DIR"
tar -xzf "$SQLITE_TARBALL" -C "$SQLITE_SOURCE_DIR" --strip-components=1
cp -a "$SQLITE_SOURCE_DIR"/. "$SQLITE_MODULE"/

(
  cd "$SQLITE_MODULE"
  "$PROJECT_ROOT/node_modules/.bin/node-gyp" rebuild \
    --force_build=1 \
    --target="$ELECTRON_VERSION" \
    --arch=x64 \
    --dist-url=https://electronjs.org/headers
)

SQLITE_BINARY="$SQLITE_MODULE/build/Release/better_sqlite3.node"
if [[ ! -f "$SQLITE_BINARY" ]] || file "$SQLITE_BINARY" | grep -qi 'PE32'; then
  printf 'better-sqlite3 is still a Windows binary; Linux rebuild did not produce a usable module.\n' >&2
  exit 1
fi

# Ship the Electron-targeted x64 rebuild, without npm's alternative platform
# prebuilds or its native test extension being eligible for load-time fallback.
rm -rf "$SQLITE_MODULE/prebuilds"
rm -f "$SQLITE_MODULE/build/Release/test_extension.node"

MAIN_BUNDLE="$APP_DIR/.webpack/main/index.js"
if [[ ! -f "$MAIN_BUNDLE" ]]; then
  printf 'Could not find the expected Electron main bundle: %s\n' "$MAIN_BUNDLE" >&2
  exit 1
fi

printf 'Applying Linux compatibility patches...\n'
NOTION_TEST_BUNDLE="$MAIN_BUNDLE" npm test --prefix "$PROJECT_ROOT"
node "$PROJECT_ROOT/scripts/patch-notion.cjs" "$MAIN_BUNDLE" "$BUILD_DIR/patch-report.json"

INSTALLER_ICON="$BUILD_DIR/payload/resources/icon-production.png"
if [[ ! -f "$INSTALLER_ICON" ]]; then
  printf 'Could not find resources/icon-production.png in the Windows payload.\n' >&2
  exit 1
fi
install -m 0644 "$INSTALLER_ICON" "$APP_DIR/icon.png"

printf 'Building a Debian package...\n'
node - "$APP_DIR/package.json" <<'NODE'
const fs = require('node:fs')
const packagePath = process.argv[2]
const appPackage = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
appPackage.author = { name: 'Local personal build', email: 'local-build@example.invalid' }
appPackage.homepage = 'https://www.notion.com'
appPackage.desktopName = 'local.personal.notion'
appPackage.build = {
  ...appPackage.build,
  appId: 'local.personal.notion',
  productName: 'Notion',
  linux: {
    ...appPackage.build?.linux,
    category: 'Utility',
    maintainer: 'Local personal build <local-build@example.invalid>',
    syncDesktopName: true,
  },
}
fs.writeFileSync(packagePath, `${JSON.stringify(appPackage, null, 2)}\n`)
NODE
APP_VERSION="$(node -p "require('$APP_DIR/package.json').version")"
APP_PROTOCOL="$(node -p "require('$APP_DIR/config.json').protocol")"
if [[ ! "$APP_PROTOCOL" =~ ^[a-z][a-z0-9+.-]*$ ]]; then
  printf 'Unexpected desktop URL protocol: %s\n' "$APP_PROTOCOL" >&2
  exit 1
fi
cd "$APP_DIR"
"$PROJECT_ROOT/node_modules/.bin/electron-builder" --linux deb --config.npmRebuild=false --publish never

mkdir -p "$PROJECT_ROOT/dist"
mapfile -d '' -t BUILT_PACKAGES < <(find "$APP_DIR/dist" -maxdepth 1 -type f -name '*.deb' -print0)
if [[ ${#BUILT_PACKAGES[@]} -ne 1 ]]; then
  printf 'Expected exactly one electron-builder .deb, found %s.\n' "${#BUILT_PACKAGES[@]}" >&2
  exit 1
fi
BUILDER_PACKAGE="${BUILT_PACKAGES[0]}"

printf 'Making the desktop icon path explicit...\n'
while IFS= read -r -d '' DEB_PACKAGE; do
  PACKAGE_STAGING="$BUILD_DIR/deb-staging"
  rm -rf "$PACKAGE_STAGING"
  dpkg-deb --raw-extract "$DEB_PACKAGE" "$PACKAGE_STAGING"
  install -m 0644 "$INSTALLER_ICON" "$PACKAGE_STAGING/opt/Notion/icon.png"
  install -m 0644 "$INSTALLER_ICON" "$PACKAGE_STAGING/opt/Notion/resources/aboutIcon.png"
  install -m 0755 "$PROJECT_ROOT/launch-notion.sh" "$PACKAGE_STAGING/opt/Notion/notion-launcher"
  DESKTOP_FILE="$(find "$PACKAGE_STAGING/usr/share/applications" -maxdepth 1 -type f -name '*.desktop' -print -quit)"
  if [[ ! -f "$DESKTOP_FILE" ]]; then
    printf 'Could not find the generated Notion desktop entry.\n' >&2
    exit 1
  fi
  sed --in-place 's|^Icon=.*$|Icon=/opt/Notion/icon.png|' "$DESKTOP_FILE"
  sed --in-place 's|^Exec=.*$|Exec=/opt/Notion/notion-launcher %U|' "$DESKTOP_FILE"
  if ! grep -Fq "x-scheme-handler/$APP_PROTOCOL;" "$DESKTOP_FILE"; then
    if grep -q '^MimeType=' "$DESKTOP_FILE"; then
      sed --in-place "/^MimeType=/s|\$|x-scheme-handler/$APP_PROTOCOL;|" "$DESKTOP_FILE"
    else
      printf 'MimeType=x-scheme-handler/%s;\n' "$APP_PROTOCOL" >> "$DESKTOP_FILE"
    fi
  fi
  if ! grep -Fxq "Version: $APP_VERSION" "$PACKAGE_STAGING/DEBIAN/control"; then
    printf 'Could not find the expected upstream package version in the control file.\n' >&2
    exit 1
  fi
  sed --in-place "s/^Version: $APP_VERSION$/Version: $APP_VERSION+local4/" "$PACKAGE_STAGING/DEBIAN/control"
  node "$PROJECT_ROOT/scripts/write-build-manifest.cjs" \
    "$PROJECT_ROOT" "$APP_DIR" "$INSTALLER" "$PACKAGE_STAGING" "$ASAR_FILE"
  POST_INSTALL_SCRIPT="$PACKAGE_STAGING/DEBIAN/postinst"
  sed --in-place \
    -e '/^if hash update-mime-database /,/^fi$/d' \
    -e '/^if hash update-desktop-database /,/^fi$/d' \
    "$POST_INSTALL_SCRIPT"
  if grep -Eq 'update-(mime|desktop)-database' "$POST_INSTALL_SCRIPT"; then
    printf 'The generated post-install script still rebuilds global desktop caches.\n' >&2
    exit 1
  fi
  cat >> "$POST_INSTALL_SCRIPT" <<'SH'

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
SH
  cat >> "$PACKAGE_STAGING/DEBIAN/postrm" <<'SH'

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
SH
  (
    cd "$PACKAGE_STAGING"
    find . -type f ! -path './DEBIAN/*' -print0 \
      | sort -z \
      | xargs -0 md5sum > DEBIAN/md5sums
  )
  PATCHED_PACKAGE="$DEB_PACKAGE.patched"
  dpkg-deb --build --root-owner-group "$PACKAGE_STAGING" "$PATCHED_PACKAGE" >/dev/null
  mv -f "$PATCHED_PACKAGE" "$DEB_PACKAGE"
done < <(printf '%s\0' "$BUILDER_PACKAGE")

FINAL_PACKAGE="$PROJECT_ROOT/dist/Notion_${APP_VERSION}+local4_amd64.deb"
mv -f "$BUILDER_PACKAGE" "$FINAL_PACKAGE"
(
  cd "$PROJECT_ROOT/dist"
  sha256sum "$(basename "$FINAL_PACKAGE")" > "$(basename "$FINAL_PACKAGE").sha256"
)

printf 'Build complete. Debian package(s) are in %s\n' "$PROJECT_ROOT/dist"
