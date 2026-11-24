#!/usr/bin/env bash
# 只读检查一个 HAP：bundle、API、权限、原生库、运行时归档、是否含旧 bundle 字符串。
# 用法：bash inspect-hap.sh <file.hap>
set -euo pipefail
hap="${1:?file.hap}"
command -v unzip >/dev/null || { echo "unzip missing" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unzip -p "$hap" module.json > "$tmp/module.json"
[ -s "$tmp/module.json" ] || { echo "module.json not found" >&2; exit 1; }

python3 - "$tmp/module.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
app = d.get("app", {})
mod = d.get("module", {})
print("bundleName :", app.get("bundleName"))
print("versionName:", app.get("versionName"), "versionCode:", app.get("versionCode"))
print("minAPI     :", app.get("minAPIVersion"))
print("targetAPI  :", app.get("targetAPIVersion"))
print("module     :", mod.get("name"), "type:", mod.get("type"))
print("deviceTypes:", mod.get("deviceTypes"))
print("permissions:")
for p in mod.get("requestPermissions", []) or []:
    print("  -", p.get("name"))
print("backgroundModes:", (mod.get("abilities") or [{}])[0].get("backgroundModes"))
PY

echo "--- libs"
unzip -l "$hap" 'libs/*' 2>/dev/null | awk 'NR>3 && $4 ~ /\.so$/ {printf "  %10d  %s\n", $1, $4}' | head -40

echo "--- runtime archives"
for f in resources/rawfile/tools/official-engine.tar.gz resources/rawfile/tools/npm.tar.gz resources/rawfile/tools/runtime-manifest.json; do
  if unzip -l "$hap" "$f" >/dev/null 2>&1; then
    printf '  %s  %s bytes\n' "$f" "$(unzip -l "$hap" "$f" | awk 'NR==4 {print $1}')"
  else
    printf '  MISSING %s\n' "$f"
  fi
done

echo "--- old bundle strings in ets/modules.abc"
if unzip -p "$hap" ets/modules.abc > "$tmp/modules.abc" 2>/dev/null; then
  bundle="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["app"]["bundleName"])' "$tmp/module.json")"
  if strings -a "$tmp/modules.abc" | grep -Fq "$bundle"; then
    echo "  FOUND $bundle -> changing bundleName without rebuilding may break module loading"
  else
    echo "  no $bundle string found (repack may be safe)"
  fi
  strings -a "$tmp/modules.abc" | grep -oE '@bundle:[^/" ]+' | sort -u | head -5 | sed 's/^/  /'
else
  echo "  ets/modules.abc not found"
fi
