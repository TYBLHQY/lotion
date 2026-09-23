#!/usr/bin/env bash
set -euo pipefail

ELECTRON_VERSION="${ELECTRON_VERSION:-43.6.0}"
if [[ -n "${NOTION_ELECTRON_BUILD_ROOT:-}" ]]; then
  BUILD_ROOT="$NOTION_ELECTRON_BUILD_ROOT"
elif [[ -n "${RUNNER_WORKSPACE:-}" ]]; then
  BUILD_ROOT="$(dirname -- "$RUNNER_WORKSPACE")/notion-electron-gtk4-${ELECTRON_VERSION}"
else
  BUILD_ROOT="${HOME:?HOME must be set}/.cache/notion-electron-gtk4-${ELECTRON_VERSION}"
fi
DEPOT_TOOLS_DIR="$BUILD_ROOT/depot_tools"
SRC_DIR="$BUILD_ROOT/src"
ELECTRON_DIR="$SRC_DIR/electron"
OUT_DIR="$SRC_DIR/out/Release"
OUTPUT_DIR="${GITHUB_WORKSPACE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}/build/inputs"
OUTPUT_ZIP="$OUTPUT_DIR/electron-v${ELECTRON_VERSION}-linux-x64.zip"

for command in git python3 pkg-config; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command" >&2
    exit 1
  fi
done

mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
if [[ ! -d "$DEPOT_TOOLS_DIR/.git" ]]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
fi
export PATH="$DEPOT_TOOLS_DIR/.cipd_bin:$DEPOT_TOOLS_DIR:$PATH"
export DEPOT_TOOLS_UPDATE=0
"$DEPOT_TOOLS_DIR/ensure_bootstrap"

if [[ ! -d "$ELECTRON_DIR/.git" ]]; then
  mkdir -p "$SRC_DIR"
  git clone --filter=blob:none --depth 1 --branch "v${ELECTRON_VERSION}" \
    https://github.com/electron/electron.git "$ELECTRON_DIR"
fi
git -C "$ELECTRON_DIR" checkout --detach "v${ELECTRON_VERSION}"

CHROMIUM_VERSION="$(python3 - "$ELECTRON_DIR/DEPS" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as deps_file:
    match = re.search(
        r"['\"]chromium_version['\"]\s*:\s*['\"]([^'\"]+)['\"]",
        deps_file.read(),
    )
if not match:
    raise SystemExit("Could not read chromium_version from Electron DEPS")
print(match.group(1))
PY
)"

# Discard stale Chromium sources but retain a matching checkout with Electron's
# applied patch commits between repeated builds.
if [[ -d "$SRC_DIR/.git" ]]; then
  CURRENT_CHROMIUM_VERSION="$(awk -F= '
    $1 == "MAJOR" { major = $2 }
    $1 == "MINOR" { minor = $2 }
    $1 == "BUILD" { build = $2 }
    $1 == "PATCH" { patch = $2 }
    END {
      if (major && minor && build && patch) {
        print major "." minor "." build "." patch
      }
    }
  ' "$SRC_DIR/chrome/VERSION" 2>/dev/null || true)"
  if [[ "$CURRENT_CHROMIUM_VERSION" != "$CHROMIUM_VERSION" ]]; then
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    git clone --filter=blob:none --depth 1 --branch "v${ELECTRON_VERSION}" \
      https://github.com/electron/electron.git "$ELECTRON_DIR"
    git -C "$ELECTRON_DIR" checkout --detach "v${ELECTRON_VERSION}"
  fi
fi

cat > "$BUILD_ROOT/.gclient" <<EOF
solutions = [
  {
    "name": "src/electron",
    "url": "https://github.com/electron/electron.git",
    "managed": False,
    "custom_deps": {
      "src": "https://github.com/chromium/chromium.git@${CHROMIUM_VERSION}",
    },
    "custom_vars": {},
  },
]
EOF

# gclient's normal fetch refspec enumerates every Chromium branch on GitHub.
# Seed a new checkout at Electron's exact tag and keep its fetch refspec narrow.
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" init
  git -C "$SRC_DIR" remote add origin https://github.com/chromium/chromium.git
  git -C "$SRC_DIR" config --replace-all remote.origin.fetch \
    "+refs/tags/${CHROMIUM_VERSION}:refs/tags/${CHROMIUM_VERSION}"
  git -C "$SRC_DIR" fetch --depth=1 --no-tags origin \
    "refs/tags/${CHROMIUM_VERSION}:refs/tags/${CHROMIUM_VERSION}"
  git -C "$SRC_DIR" checkout --force --detach "$CHROMIUM_VERSION"
else
  git -C "$SRC_DIR" remote set-url origin https://github.com/chromium/chromium.git
  git -C "$SRC_DIR" config --replace-all remote.origin.fetch \
    "+refs/tags/${CHROMIUM_VERSION}:refs/tags/${CHROMIUM_VERSION}"
fi

cd "$BUILD_ROOT"
SYNC_KEY="${ELECTRON_VERSION}:${CHROMIUM_VERSION}"
SYNC_MARKER="$BUILD_ROOT/.gclient-sync-key"
CACHED_ELECTRON_TAG="$(git -C "$ELECTRON_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ -f "$SYNC_MARKER" && "$(<"$SYNC_MARKER")" == "$SYNC_KEY" \
    && "$CACHED_ELECTRON_TAG" == "v${ELECTRON_VERSION}" \
    && -f "$BUILD_ROOT/.gclient_entries" ]] \
    && grep -Fq "'src': 'https://github.com/chromium/chromium.git@${CHROMIUM_VERSION}'" \
      "$BUILD_ROOT/.gclient_entries"; then
  printf 'Using the existing Electron %s / Chromium %s dependency sync.\n' \
    "$ELECTRON_VERSION" "$CHROMIUM_VERSION"
else
  printf 'Synchronizing Electron %s and its pinned Chromium source...\n' "$ELECTRON_VERSION"
  printf 'Chromium revision from Electron DEPS: %s\n' "$CHROMIUM_VERSION"
  gclient sync --no-history --nohooks --jobs="${GCLIENT_JOBS:-4}"
  printf '%s\n' "$SYNC_KEY" > "$SYNC_MARKER"
fi
# Chromium's shared Python spec includes OpenCV and data-analysis wheels for
# unrelated tooling. Electron's GTK4 build does not use cv2, pandas, or pyarrow;
# the Artifact Registry/Mihomo path has returned bytes failing Chromium's pinned
# SHA-256 checks for its large wheels. Remove only these unused wheels from this
# local build's vpython spec; keep all remaining pinned checks intact.
python3 - "$SRC_DIR/.vpython3" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as spec_file:
    spec = spec_file.read()
for package in ("opencv_python", "pandas", "pyarrow"):
    spec, removed = re.subn(
        rf'wheel: <\n  name: "infra/python/wheels/{package}/[^"\n]+"\n.*?\n>\n',
        "",
        spec,
        count=1,
        flags=re.DOTALL,
    )
    if removed > 1:
        raise SystemExit(f"Found multiple Chromium {package} wheels in .vpython3")
with open(path, "w", encoding="utf-8") as spec_file:
    spec_file.write(spec)
print("Skipped unused Chromium OpenCV/pandas/pyarrow wheels for this Electron build.")
PY
# Electron's local build does not use sentry-cli; it is only needed by the
# release symbol uploader. Avoid an unrelated CDN download during yarn install.
SENTRYCLI_SKIP_DOWNLOAD=1 gclient runhooks

if [[ ! -f "$SRC_DIR/build/install-build-deps.sh" ]]; then
  printf 'Chromium dependency installer was not found after source sync.\n' >&2
  exit 1
fi
if ! pkg-config --exists gtk4; then
  printf 'GTK4 development files are missing. Install libgtk-4-dev on the build runner.\n' >&2
  exit 1
fi
if [[ ! -x "$SRC_DIR/build/install-build-deps.sh" ]]; then
  printf 'Chromium build dependency installer is missing.\n' >&2
  exit 1
fi
printf 'Generating the GTK4 GN configuration...\n'
cd "$SRC_DIR"
gn gen out/Release --args='import("//electron/build/args/testing.gn") gtk_version=4 is_debug=false dcheck_always_on=false symbol_level=0 blink_symbol_level=0 v8_symbol_level=0'
gtk_version_args=$(gn args out/Release --list=gtk_version)
printf '%s\n' "$gtk_version_args"
if ! grep -Fq 'Current value = 4' <<<"$gtk_version_args"; then
  printf 'GN did not configure GTK 4 as requested.\n' >&2
  exit 1
fi

printf 'Building Electron %s with GTK4...\n' "$ELECTRON_VERSION"
autoninja -C out/Release -j "${NINJA_JOBS:-4}" electron:electron_dist_zip
if [[ ! -f "$OUT_DIR/dist.zip" ]]; then
  printf 'Electron build completed without the expected dist.zip.\n' >&2
  exit 1
fi

install -m 0644 "$OUT_DIR/dist.zip" "$OUTPUT_ZIP"
printf 'GTK4 Electron distribution ready: %s\n' "$OUTPUT_ZIP"
