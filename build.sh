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

NPM_CACHE_DIR="$(npm config get cache)"
ASAR_BIN="$(find "$NPM_CACHE_DIR/_npx" -type f -path '*/node_modules/@electron/asar/bin/asar.js' -print -quit 2>/dev/null || true)"
if [[ -n "$ASAR_BIN" ]]; then
  node "$ASAR_BIN" extract "$ASAR_FILE" "$APP_DIR"
else
  npx --yes @electron/asar extract "$ASAR_FILE" "$APP_DIR"
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
  npx --yes node-gyp rebuild \
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

MAIN_BUNDLE="$APP_DIR/.webpack/main/index.js"
if [[ ! -f "$MAIN_BUNDLE" ]]; then
  printf 'Could not find the expected Electron main bundle: %s\n' "$MAIN_BUNDLE" >&2
  exit 1
fi

printf 'Applying Linux compatibility patches...\n'
node - "$MAIN_BUNDLE" <<'NODE'
const fs = require('node:fs')
const bundlePath = process.argv[2]
let bundle = fs.readFileSync(bundlePath, 'utf8')
const replacements = [
  [
    'return!(!n||!r)||"win32"===process.platform',
    'return!(!n||!r)||"linux"===process.platform',
  ],
  [
    'n="win32"===process.platform?function(e,t){const{isOpenAtLoginEnabled:n,isQuickSearchEnabled:r,isHideLastWindowOnCloseEnabled:o}=t;',
    'n="linux"===process.platform?function(e,t){const{isOpenAtLoginEnabled:n,isQuickSearchEnabled:r,isHideLastWindowOnCloseEnabled:o}=t;',
  ],
  [
    'o="win32"===process.platform?[{type:"separator"},(0,p.buildTroubleshootingMenu)(e,s.setSystemMenu),{type:"separator"}]:[]',
    'o="linux"===process.platform?[{type:"separator"},(0,p.buildTroubleshootingMenu)(e,s.setSystemMenu),{type:"separator"}]:[]',
  ],
]
for (const [before, after] of replacements) {
  if (bundle.split(before).length !== 2) {
    console.error(`Expected exactly one Linux patch target; found ${bundle.split(before).length - 1}.`)
    process.exit(1)
  }
  bundle = bundle.replace(before, after)
}
const windowsTrayBinding = 'this.tray=new l.Tray(this.getIcon()),this.tray.on("click",()=>{this.onClick()}),this.tray.on("right-click",()=>this.onRightClick()),this.tray.setToolTip(l.app.getName())'
const linuxTrayBinding = 'this.tray=new l.Tray(this.getIcon()),"linux"===process.platform?this.tray.setContextMenu(this.trayMenu):this.tray.on("right-click",()=>this.onRightClick()),this.tray.on("click",()=>{this.onClick()}),this.tray.setToolTip(l.app.getName())'
if (bundle.split(windowsTrayBinding).length !== 2) {
  console.error('Expected tray event binding was not found; refusing to patch an unknown app build.')
  process.exit(1)
}
bundle = bundle.replace(windowsTrayBinding, linuxTrayBinding)
fs.writeFileSync(bundlePath, bundle)
NODE

INSTALLER_ICON="$BUILD_DIR/payload/resources/icon-production.png"
if [[ ! -f "$INSTALLER_ICON" ]]; then
  printf 'Could not find resources/icon-production.png in the Windows payload.\n' >&2
  exit 1
fi
install -m 0644 "$INSTALLER_ICON" "$APP_DIR/icon.png"

printf 'Building a Debian package...\n'
node - "$APP_DIR/package.json" "$ELECTRON_VERSION" <<'NODE'
const fs = require('node:fs')
const path = require('node:path')
const packagePath = process.argv[2]
const electronVersion = process.argv[3]
const appPackage = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
appPackage.author = { name: 'Local personal build', email: 'local-build@example.invalid' }
appPackage.homepage = 'https://www.notion.com'
appPackage.desktopName = 'local.personal.notion'
let electronDist = null
if (process.env.NOTION_ELECTRON_DIST) {
  if (appPackage.devDependencies?.electron !== electronVersion) {
    console.error(`Custom Electron ${electronVersion} does not match the app's Electron ${appPackage.devDependencies?.electron}.`)
    process.exit(1)
  }
  electronDist = path.join(
    process.env.NOTION_ELECTRON_DIST,
    `electron-v${electronVersion}-linux-x64.zip`,
  )
  if (!fs.existsSync(electronDist)) {
    console.error(`Custom Electron distribution was not found: ${electronDist}`)
    process.exit(1)
  }
}
appPackage.build = {
  ...appPackage.build,
  ...(electronDist ? { electronDist: process.env.NOTION_ELECTRON_DIST } : {}),
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
cd "$APP_DIR"
npx --yes electron-builder --linux deb --config.npmRebuild=false --publish never

mkdir -p "$PROJECT_ROOT/dist"
rm -f "$PROJECT_ROOT/dist"/*.deb
find "$APP_DIR/dist" -maxdepth 1 -type f -name '*.deb' -exec cp -f {} "$PROJECT_ROOT/dist/" \;
if ! find "$PROJECT_ROOT/dist" -maxdepth 1 -type f -name '*.deb' -print -quit | grep -q .; then
  printf 'electron-builder finished but did not produce a .deb package.\n' >&2
  exit 1
fi

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
  if ! grep -Fxq "Version: $APP_VERSION" "$PACKAGE_STAGING/DEBIAN/control"; then
    printf 'Could not find the expected upstream package version in the control file.\n' >&2
    exit 1
  fi
  sed --in-place "s/^Version: $APP_VERSION$/Version: $APP_VERSION+local2/" "$PACKAGE_STAGING/DEBIAN/control"
  POST_INSTALL_SCRIPT="$PACKAGE_STAGING/DEBIAN/postinst"
  sed --in-place \
    -e '/^if hash update-mime-database /,/^fi$/d' \
    -e '/^if hash update-desktop-database /,/^fi$/d' \
    "$POST_INSTALL_SCRIPT"
  if grep -Eq 'update-(mime|desktop)-database' "$POST_INSTALL_SCRIPT"; then
    printf 'The generated post-install script still rebuilds global desktop caches.\n' >&2
    exit 1
  fi
  (
    cd "$PACKAGE_STAGING"
    find . -type f ! -path './DEBIAN/*' -print0 \
      | sort -z \
      | xargs -0 md5sum > DEBIAN/md5sums
  )
  PATCHED_PACKAGE="$DEB_PACKAGE.patched"
  dpkg-deb --build --root-owner-group "$PACKAGE_STAGING" "$PATCHED_PACKAGE" >/dev/null
  mv -f "$PATCHED_PACKAGE" "$DEB_PACKAGE"
done < <(find "$PROJECT_ROOT/dist" -maxdepth 1 -type f -name '*.deb' -print0)

BUILT_PACKAGE="$(find "$PROJECT_ROOT/dist" -maxdepth 1 -type f -name '*.deb' -print -quit)"
FINAL_PACKAGE="$PROJECT_ROOT/dist/Notion_${APP_VERSION}+local2_amd64.deb"
mv -f "$BUILT_PACKAGE" "$FINAL_PACKAGE"

printf 'Build complete. Debian package(s) are in %s\n' "$PROJECT_ROOT/dist"
