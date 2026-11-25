#!/usr/bin/env bash
# Bootstrap a DSH HOS build tree from the vendored app/ source.
#
#   BUNDLE_NAME=com.yourname.dshhos bash scripts/bootstrap.sh
#
# Optional overrides:
#   WORKDIR            target project dir (default: ./build)
#   APP_SRC            existing app source tree (skip vendored copy)
#   RUNTIME_HAP        existing runtime HAP (skip download)
#   ASSET_BASE         release base URL (default: GitHub; use a mirror if blocked)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="${WORKDIR:-$ROOT/build}"
BUNDLE_NAME="${BUNDLE_NAME:-com.dsh.hos}"
APP_NAME="${APP_NAME:-DSH HOS}"
BASE="${ASSET_BASE:-https://github.com/Jerrylee2044/dsh-hos/releases/download/v0.1.0-assets}"
CACHE="$ROOT/.cache"
EXTRACT="$ROOT/.bootstrap"

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need curl; need unzip; need python3

echo "== 1/4 source"
if [ -f "$WORKDIR/hvigorfile.ts" ]; then
  echo "   reuse $WORKDIR"
elif [ -n "${APP_SRC:-}" ]; then
  rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"; cp -a "$APP_SRC/." "$WORKDIR/"
  echo "   copied $APP_SRC"
else
  rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"; cp -a "$ROOT/app/." "$WORKDIR/"
  echo "   copied vendored app/ source"
fi

echo "== 2/4 runtime assets"
mkdir -p "$CACHE"
HAP="${RUNTIME_HAP:-$CACHE/DSH-HOS-0.2.2-rc.5-unsigned.hap}"
if [ ! -f "$HAP" ]; then
  echo "   downloading runtime HAP (about 360 MB)..."
  curl -fL --retry 3 -o "$HAP.part" "$BASE/DSH-HOS-0.2.2-rc.5-unsigned.hap"
  mv "$HAP.part" "$HAP"
fi

echo "== 3/4 extract runtime assets"
rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
unzip -q "$HAP" \
  'libs/*' \
  'resources/rawfile/tools/*' \
  -d "$EXTRACT"

mkdir -p "$WORKDIR/entry/libs/arm64-v8a"
cp -a "$EXTRACT/libs/arm64-v8a/." "$WORKDIR/entry/libs/arm64-v8a/"
mkdir -p "$WORKDIR/entry/src/main/resources/rawfile/tools"
cp -a "$EXTRACT/resources/rawfile/tools/." "$WORKDIR/entry/src/main/resources/rawfile/tools/"

echo "== 4/4 patch project"
"$ROOT/scripts/patch-project.sh" "$WORKDIR" "$BUNDLE_NAME" "$APP_NAME"

cat <<EOF

Done. Project: $WORKDIR
Bundle:      $BUNDLE_NAME
Next:
  export TOOL_HOME=/path/to/command-line-tools
  PROJECT="$WORKDIR" bash "$ROOT/scripts/build-hap.sh"
  # then sign with your own AGC debug cert/profile; see docs/SIGN-INSTALL.md
EOF
