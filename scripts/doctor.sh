#!/usr/bin/env bash
# Environment check for building/signing/installing DSH HOS.
set -uo pipefail

ok() { printf '  [ OK ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; }
note() { printf '  [WARN] %s\n' "$*"; }

echo "== host"
for c in java node python3 git curl unzip; do
  if command -v "$c" >/dev/null; then ok "$c: $(command -v "$c")"; else bad "$c missing"; fi
done
java -version 2>&1 | head -1 | sed 's/^/    /'
node -v 2>/dev/null | sed 's/^/    node /'

echo "== command-line tools"
if [ -n "${TOOL_HOME:-}" ] && [ -f "$TOOL_HOME/tools/hvigor/bin/hvigorw.js" ]; then
  ok "TOOL_HOME=$TOOL_HOME"
else
  note "TOOL_HOME not set or not a command-line-tools tree"
fi
if [ -n "${TOOL_HOME:-}" ]; then
  hdc="$TOOL_HOME/sdk/default/openharmony/toolchains/hdc"
  sign="$TOOL_HOME/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"
  [ -x "$hdc" ] && ok "hdc: $hdc" || bad "hdc missing"
  [ -f "$sign" ] && ok "hap-sign-tool: $sign" || bad "hap-sign-tool missing"
fi

echo "== device"
HDC="${HDC:-${TOOL_HOME:+$TOOL_HOME/sdk/default/openharmony/toolchains/hdc}}"
if [ -n "${HDC:-}" ] && [ -x "$HDC" ]; then
  targets="$("$HDC" list targets 2>/dev/null | sed '/^$/d')"
  if [ -n "$targets" ] && [ "$targets" != "[Empty]" ]; then
    ok "targets: $targets"
    "$HDC" shell bm get --udid 2>/dev/null | tail -1 | sed 's/^/    UDID: /'
  else
    bad "no device: enable USB debugging and allow the prompt"
  fi
else
  bad "hdc not found (set TOOL_HOME or HDC)"
fi
