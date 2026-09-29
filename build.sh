#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
STAGE="$BUILD_DIR/package-root"
REF_FILE="$BUILD_DIR/notion.flatpakref"
APP_ID="${NOTION_APP_ID:-com.notion.app.desktop.notion}"
APP_REF_URL="${NOTION_FLATPAK_REF_URL:-https://app.linux-packages.notion.com/notion.flatpakref}"

for required_command in curl flatpak dpkg-deb desktop-file-validate python3 git; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$required_command" >&2
    exit 1
  fi
done

rm -rf "$BUILD_DIR/package-root" "$PROJECT_ROOT/dist"
mkdir -p "$BUILD_DIR" "$PROJECT_ROOT/dist"
printf 'Downloading Notion’s official Flatpak reference...\n'
curl --fail --location --retry 3 "$APP_REF_URL" --output "$REF_FILE"
if ! grep -Fxq "Name=$APP_ID" "$REF_FILE"; then
  printf 'The Flatpak reference did not contain the expected application ID (%s).\n' "$APP_ID" >&2
  exit 1
fi

printf 'Installing the official app and its runtime into a temporary user installation...\n'
flatpak install --user --noninteractive --or-update --from "$REF_FILE"
APP_LOCATION="$(flatpak info --user --show-location "$APP_ID")"
RUNTIME_REF="$(flatpak info --user --show-runtime "$APP_ID")"
if [[ -z "$RUNTIME_REF" || "$RUNTIME_REF" == "-" ]]; then
  printf 'The official app does not report a Flatpak runtime; refusing to make an incomplete package.\n' >&2
  exit 1
fi
RUNTIME_LOCATION="$(flatpak info --user --show-location "$RUNTIME_REF")"
APP_FILES="$APP_LOCATION/files"
RUNTIME_FILES="$RUNTIME_LOCATION/files"
if [[ ! -d "$APP_FILES" || ! -d "$RUNTIME_FILES" ]]; then
  printf 'Could not find the installed app or runtime payload.\n' >&2
  exit 1
fi

APP_METADATA="$BUILD_DIR/app-metadata.ini"
flatpak info --user --show-metadata "$APP_ID" > "$APP_METADATA"
APP_COMMAND="$(python3 - "$APP_METADATA" <<'PY'
import configparser
import sys

metadata = configparser.ConfigParser(interpolation=None)
metadata.read(sys.argv[1])
print(metadata.get("Application", "command", fallback=""))
PY
)"
if [[ -z "$APP_COMMAND" || "$APP_COMMAND" == */* || "$APP_COMMAND" == *[[:space:]]* ]]; then
  printf 'Could not determine a safe executable name from the app metadata: %s\n' "$APP_COMMAND" >&2
  exit 1
fi
APP_EXECUTABLE="$APP_FILES/bin/$APP_COMMAND"
if [[ ! -x "$APP_EXECUTABLE" ]]; then
  printf 'The app command is missing or not executable: %s\n' "$APP_EXECUTABLE" >&2
  exit 1
fi

APP_VERSION="$(flatpak info --user "$APP_ID" | sed -n 's/^Version:[[:space:]]*//p' | head -n 1)"
if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="$(python3 - "$APP_FILES" <<'PY'
import glob
import json
import os
import sys
import xml.etree.ElementTree as ET

root_dir = sys.argv[1]
paths = glob.glob(root_dir + "/**/*.metainfo.xml", recursive=True)
paths += glob.glob(root_dir + "/**/*.appdata.xml", recursive=True)
for path in paths:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        continue
    for element in root.iter():
        if element.tag.split("}")[-1] == "release":
            version = element.get("version", "")
            if version:
                print(version)
                raise SystemExit(0)
for directory, _, filenames in os.walk(root_dir):
    if "package.json" not in filenames:
        continue
    path = os.path.join(directory, "package.json")
    try:
        with open(path, encoding="utf-8") as stream:
            package = json.load(stream)
    except (OSError, json.JSONDecodeError):
        continue
    identity = " ".join(str(package.get(key, "")) for key in ("name", "productName")).lower()
    if "notion" in identity and package.get("version"):
        print(package["version"])
        raise SystemExit(0)
PY
)"
fi
VERSION_SOURCE="flatpak-metadata"
if [[ -z "$APP_VERSION" ]]; then
  APP_VERSION="${NOTION_VERSION_FALLBACK:-7.35.1}"
  VERSION_SOURCE="latest-known-desktop-release"
fi
if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)*([+~-][A-Za-z0-9.+~:-]+)?$ ]]; then
  printf 'Could not determine a Debian-safe upstream application version: %s\n' "$APP_VERSION" >&2
  exit 1
fi

APP_COMMIT="$(flatpak info --user --show-commit "$APP_ID")"
if [[ ! "$APP_COMMIT" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'Unexpected Flatpak commit checksum: %s\n' "$APP_COMMIT" >&2
  exit 1
fi
SHORT_COMMIT="${APP_COMMIT:0:12}"
SOURCE_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
SOURCE_SHORT="${SOURCE_COMMIT:0:12}"
BUILD_TIMESTAMP="$(date -u +%Y%m%d.%H%M%S)"
DEB_VERSION="${APP_VERSION}+notion.${BUILD_TIMESTAMP}.flatpak.${SHORT_COMMIT}.pkg.${SOURCE_SHORT}"
ARCH="$(dpkg --print-architecture)"

printf 'Preparing Notion %s from Flatpak commit %s for %s...\n' "$APP_VERSION" "$SHORT_COMMIT" "$ARCH"
install -d "$STAGE/opt/Notion/app" "$STAGE/opt/Notion/runtime" \
  "$STAGE/usr/bin" "$STAGE/usr/share/applications" "$STAGE/usr/share/icons/hicolor" \
  "$STAGE/usr/share/doc/notion-desktop" "$STAGE/DEBIAN"
cp -a "$APP_FILES/." "$STAGE/opt/Notion/app/"
cp -a "$RUNTIME_FILES/." "$STAGE/opt/Notion/runtime/"
cp "$APP_METADATA" "$STAGE/usr/share/doc/notion-desktop/flatpak-metadata.ini"
printf '%s\n' "$APP_COMMIT" > "$STAGE/usr/share/doc/notion-desktop/flatpak-commit"

cat > "$STAGE/opt/Notion/notion-launcher" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/Notion
APP="$ROOT/app"
RUNTIME="$ROOT/runtime"

# Keep the Flatpak runtime's libraries available without installing Flatpak.
LIB_DIRS=()
while IFS= read -r dir; do LIB_DIRS+=("$dir"); done < <(
  find "$APP" "$RUNTIME/usr" -type f -name '*.so*' -printf '%h\n' 2>/dev/null | sort -u
)
joined=""
if ((${#LIB_DIRS[@]})); then
  joined="$(IFS=:; printf '%s' "${LIB_DIRS[*]}")"
  export LD_LIBRARY_PATH="$joined${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
export PATH="$APP/bin:$RUNTIME/usr/bin:$PATH"
export XDG_DATA_DIRS="$APP/share:$RUNTIME/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export GIO_EXTRA_MODULES="$RUNTIME/usr/lib/gio/modules${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"

config_home="${XDG_CONFIG_HOME:-${HOME:?HOME must be set}/.config}"
user_data="$config_home/Notion"
flatpak_profile="${HOME:?HOME must be set}/.var/app/@APP_ID@/config/Notion"
# Preserve an existing official Flatpak profile when switching to the deb.
if [[ ! -e "$user_data" && -d "$flatpak_profile" ]]; then
  mkdir -p "$config_home"
  cp -a "$flatpak_profile" "$user_data"
fi

executable="$APP/bin/@APP_COMMAND@"
if [[ "$(od -An -tx1 -N4 "$executable" | tr -d ' \n')" == 7f454c46 ]]; then
  loader=""
  case "$(uname -m)" in
    x86_64) loader="$(find -L "$RUNTIME/usr/lib" -type f -name 'ld-linux-x86-64.so.2' -print -quit 2>/dev/null || true)" ;;
    aarch64) loader="$(find -L "$RUNTIME/usr/lib" -type f -name 'ld-linux-aarch64.so.1' -print -quit 2>/dev/null || true)" ;;
  esac
  if [[ -n "$loader" ]]; then
    exec "$loader" --library-path "$joined" "$executable" --user-data-dir="$user_data" "$@"
  fi
fi
exec "$executable" --user-data-dir="$user_data" "$@"
SH
sed -i \
  -e "s|@APP_ID@|$APP_ID|g" \
  -e "s|@APP_COMMAND@|$APP_COMMAND|g" \
  "$STAGE/opt/Notion/notion-launcher"
chmod 0755 "$STAGE/opt/Notion/notion-launcher"

# Preserve the upstream desktop metadata and icon where possible.
SOURCE_DESKTOP="$(find "$APP_FILES/share/applications" -maxdepth 1 -type f -name '*.desktop' -print -quit 2>/dev/null || true)"
if [[ -n "$SOURCE_DESKTOP" ]]; then
  cp "$SOURCE_DESKTOP" "$STAGE/usr/share/applications/notion.desktop"
  sed -i -E \
    -e 's|^Exec=.*$|Exec=/opt/Notion/notion-launcher %U|' \
    -e 's|^TryExec=.*$|TryExec=/opt/Notion/notion-launcher|' \
    -e 's|^Icon=.*$|Icon=notion|' \
    "$STAGE/usr/share/applications/notion.desktop"
else
  cat > "$STAGE/usr/share/applications/notion.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Notion
Comment=The connected workspace
Exec=/opt/Notion/notion-launcher %U
TryExec=/opt/Notion/notion-launcher
Icon=notion
Terminal=false
Categories=Office;
MimeType=x-scheme-handler/notion;
DESKTOP
fi
if ! grep -Fq 'x-scheme-handler/notion;' "$STAGE/usr/share/applications/notion.desktop"; then
  if grep -q '^MimeType=' "$STAGE/usr/share/applications/notion.desktop"; then
    sed -i '/^MimeType=/s|$|x-scheme-handler/notion;|' "$STAGE/usr/share/applications/notion.desktop"
  else
    printf 'MimeType=x-scheme-handler/notion;\n' >> "$STAGE/usr/share/applications/notion.desktop"
  fi
fi

ICON_SOURCE="$(find "$APP_FILES/share/icons" -type f \( -iname '*.png' -o -iname '*.svg' \) -path '*/apps/*' -print -quit 2>/dev/null || true)"
if [[ -n "$ICON_SOURCE" ]]; then
  ICON_REL="${ICON_SOURCE#"$APP_FILES/share/icons/"}"
  ICON_DIR="$(dirname "$ICON_REL")"
  ICON_EXT="${ICON_SOURCE##*.}"
  install -D -m 0644 "$ICON_SOURCE" "$STAGE/usr/share/icons/$ICON_DIR/notion.$ICON_EXT"
else
  printf 'The official app payload did not contain an application icon.\n' >&2
  exit 1
fi

cat > "$STAGE/DEBIAN/control" <<EOF
Package: notion-desktop
Version: $DEB_VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: TYBLHQY <noreply@example.invalid>
Depends: libc6, libstdc++6, libgcc-s1, libx11-6, libx11-xcb1, libxcb1, libxext6, libxfixes3, libxrender1, libxcomposite1, libxdamage1, libxrandr2, libxkbcommon0, libnss3, libasound2t64 | libasound2, libgbm1, libdrm2
Description: Notion desktop for Linux, packaged from Notion's official Flatpak
 This Debian package includes the official Notion Linux application and its
 Flatpak runtime libraries. Flatpak itself is not required at runtime.
EOF

cat > "$STAGE/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
exit 0
SH
cat > "$STAGE/DEBIAN/postrm" <<'SH'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
exit 0
SH
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
desktop-file-validate "$STAGE/usr/share/applications/notion.desktop"

PACKAGE="$PROJECT_ROOT/dist/notion-desktop_${DEB_VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$STAGE" "$PACKAGE" >/dev/null
dpkg-deb --info "$PACKAGE" >/dev/null
python3 - "$PROJECT_ROOT/dist/build-metadata.json" "$APP_VERSION" "$VERSION_SOURCE" "$APP_COMMIT" "$SHORT_COMMIT" "$SOURCE_COMMIT" "$SOURCE_SHORT" "$BUILD_TIMESTAMP" "$PACKAGE" <<'PY'
import json
import os
import sys

path, version, version_source, commit, short_commit, source_commit, source_short, build_timestamp, package = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({
        "version": version,
        "version_source": version_source,
        "commit": commit,
        "short_commit": short_commit,
        "source_commit": source_commit,
        "source_short": source_short,
        "build_timestamp": build_timestamp,
        "tag": f"v{version}-flatpak-{short_commit}-pkg-{source_short}",
        "package": os.path.basename(package),
    }, stream, indent=2)
    stream.write("\n")
PY
printf 'Build complete: %s\n' "$PACKAGE"
printf 'Upstream version: %s\nFlatpak commit: %s\n' "$APP_VERSION" "$APP_COMMIT"
