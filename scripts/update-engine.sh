#!/usr/bin/env bash
# Update the DSH engine from the DeepSeek Harness npm package.
#
#   PROJECT=./build bash scripts/update-engine.sh 0.2.2-rc.5
#   PROJECT=./build BUILD=1 bash scripts/update-engine.sh 0.2.3-alpha.1
#
# This intentionally does NOT use the legacy upstream release. The
# HarmonyOS shell/native runtime stays as-is; only @deepseek-ai/dsh and its
# dependency tree are replaced.
set -euo pipefail

VERSION="${1:?usage: update-engine.sh <dsh-version>  (e.g. 0.2.2-rc.5)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${PROJECT:-$ROOT/build}"
NODE="${NODE:-node}"
NPM="${NPM:-npm}"

[ -f "$PROJECT/hvigorfile.ts" ] || {
  echo "no app project at $PROJECT; run scripts/bootstrap.sh first" >&2
  exit 1
}
TOOLS="$PROJECT/entry/src/main/resources/rawfile/tools"
BASE_ENGINE="$TOOLS/official-engine.tar.gz"
[ -f "$BASE_ENGINE" ] || { echo "missing base engine: $BASE_ENGINE" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dsh-engine.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
echo "== 1/6 install @deepseek-ai/dsh@$VERSION"
cd "$TMP"
npm init -y >/dev/null 2>&1
"$NPM" install --ignore-scripts --no-audit --no-fund "semver@7" "@deepseek-ai/dsh@$VERSION" 2>&1 | tail -6

REQ="$("$NODE" -p "require('$TMP/node_modules/@deepseek-ai/dsh/package.json').engines.node")"
CUR="$("$NODE" -v | sed 's/^v//')"
echo "   engine requires node $REQ; host node $CUR"
if ! "$NODE" -e "const s=require('$TMP/node_modules/semver'); process.exit(s.satisfies(process.argv[1], process.argv[2])?0:1)" "$CUR" "$REQ"; then
  if [ "${ALLOW_NODE_MISMATCH:-0}" = "1" ]; then
    echo "   WARNING: host Node $CUR does not satisfy $REQ (ALLOW_NODE_MISMATCH=1)" >&2
  else
    echo "ERROR: host Node $CUR does not satisfy $REQ" >&2
    echo "       use a compatible Node, or choose an older DSH version" >&2
    exit 1
  fi
fi

echo "== 2/6 dump web profile"
mkdir -p "$TMP/home"
if ! DSH_HOME="$TMP/home" "$NODE" "$TMP/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  --profile web --dump-config > "$TMP/dump.yml" 2> "$TMP/dump.err"; then
  echo "ERROR: --dump-config failed for $VERSION" >&2
  head -30 "$TMP/dump.err" >&2
  exit 1
fi
entries="$(grep -c "name: '" "$TMP/dump.yml" || true)"
echo "   plugins: $entries"
[ "$entries" -gt 100 ] || { echo "plugin dump failed" >&2; cat "$TMP/dump.err" >&2; exit 1; }
if [ -s "$TMP/dump.err" ]; then
  echo "--- dump stderr"; head -20 "$TMP/dump.err"
fi

echo "== 3/6 compute ship list"
"$NODE" "$ROOT/app/scripts/engine-prune/ship-from-dump.mjs" \
  "$TMP/dump.yml" "$TMP/node_modules" "$TMP/ship.txt" 2>&1 | tail -3
[ -s "$TMP/ship.txt" ] || { echo "empty ship list" >&2; exit 1; }

echo "== 4/6 assemble engine"
mkdir -p "$TMP/engine/node_modules" "$TMP/base"
tar -C "$TMP/base" -xzf "$BASE_ENGINE"
tar -C "$TMP/node_modules" -czf "$TMP/shipped.tar.gz" -T "$TMP/ship.txt"
tar -C "$TMP/engine/node_modules" -xzf "$TMP/shipped.tar.gz"

# Native addons are built for HarmonyOS arm64 and stay with the shell. The
# package versions/ABI are stable across the DSH 0.2.2 series.
for libc in musl gnu; do
  src="$TMP/base/node_modules/node-addon-require-builtin/build/napi/napi-v9-linux-arm64-$libc/require_builtin.node"
  dst="$TMP/engine/node_modules/node-addon-require-builtin/build/napi/napi-v9-linux-arm64-$libc"
  [ -f "$src" ] || { echo "missing base native: $src" >&2; exit 1; }
  mkdir -p "$dst"; cp "$src" "$dst/"
  mkdir -p "$TMP/engine/node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/$libc"
  cp "$TMP/base/node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/$libc/system.node" \
     "$TMP/engine/node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/$libc/"
done
cp "$TMP/base/node_modules/@deepseek-ai/node-addon-system-linux-arm64/package.json" \
   "$TMP/engine/node_modules/@deepseek-ai/node-addon-system-linux-arm64/" 2>/dev/null || true

mkdir -p "$TMP/engine/node_modules/node-pty/build/Release"
cp "$TMP/base/node_modules/node-pty/build/Release/pty.node" \
   "$TMP/engine/node_modules/node-pty/build/Release/"

mkdir -p "$TMP/engine/harmony"
cp "$PROJECT/native/terminal-host.cjs" "$TMP/engine/harmony/"
cp "$PROJECT/native/node-preload.mjs" "$TMP/engine/harmony/"

# @vscode/ripgrep resolves a platform package; on HarmonyOS point it at the
# IEC-launched rg binary instead.
RIPGREP="$TMP/engine/node_modules/@vscode/ripgrep"
rm -rf "$RIPGREP"; mkdir -p "$RIPGREP/lib"
cat > "$RIPGREP/package.json" <<'EOF'
{
  "name": "@vscode/ripgrep",
  "version": "1.18.0-harmony.1",
  "type": "module",
  "main": "./lib/index.js",
  "exports": { ".": { "default": "./lib/index.js" } },
  "license": "MIT"
}
EOF
cat > "$RIPGREP/lib/index.js" <<'EOF'
import path from 'node:path';
const root = process.env.IEC_SYSROOT || '';
export const rgPath = path.join(root, 'bin', 'rg');
EOF

cp "$TMP/package-lock.json" "$TMP/engine/package-lock.json" 2>/dev/null || true
tar -C "$TMP/engine" -czf "$TMP/official-engine.tar.gz" .

echo "== 5/6 install engine into project"
cp "$TMP/official-engine.tar.gz" "$BASE_ENGINE"
( cd "$TOOLS" && sha256sum official-engine.tar.gz > official-engine.sha256 )
python3 - "$TOOLS/runtime-manifest.json" "$VERSION" <<'PY'
import json, sys
p, version = sys.argv[1:3]
d = json.load(open(p))
d['engineVersion'] = version
d['version'] = version + '-pending'
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
PY
( cd "$PROJECT" && "$NODE" scripts/runtime-manifest.mjs sync )

# Bump versionCode so `hdc install -r` accepts the new HAP.
if [ -n "${APP_VERSION_CODE:-}" ]; then
  NEW_CODE="$APP_VERSION_CODE"
else
  OLD_CODE="$(python3 - "$PROJECT/AppScope/app.json5" <<'PY2'
import re, sys
print(re.search(r'"versionCode"\s*:\s*(\d+)', open(sys.argv[1]).read()).group(1))
PY2
)"
  NEW_CODE=$((OLD_CODE + 1))
fi
python3 - "$PROJECT/AppScope/app.json5" "$NEW_CODE" "${APP_VERSION_NAME:-}" <<'PY2'
import re, sys
p, code, name = sys.argv[1:4]
s = open(p).read()
s = re.sub(r'"versionCode"\s*:\s*\d+', f'"versionCode": {code}', s, count=1)
if name:
    s = re.sub(r'"versionName"\s*:\s*"[^"]*"', f'"versionName": "{name}"', s, count=1)
open(p, 'w').write(s)
PY2
echo "   app versionCode -> $NEW_CODE${APP_VERSION_NAME:+ (versionName $APP_VERSION_NAME)}"

echo "== 6/6 done"
ls -lh "$BASE_ENGINE"
echo "engine: $VERSION, plugins: $entries"
echo "next: PROJECT=\"$PROJECT\" bash scripts/build-hap.sh"
if [ "${BUILD:-0}" = "1" ]; then
  PROJECT="$PROJECT" bash "$ROOT/scripts/build-hap.sh"
fi
