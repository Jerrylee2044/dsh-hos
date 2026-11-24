#!/usr/bin/env bash
# Build an unsigned HAP with the HarmonyOS Linux command-line tools.
#
#   TOOL_HOME=/path/to/command-line-tools PROJECT=./build bash scripts/build-hap.sh
set -euo pipefail

: "${TOOL_HOME:?set TOOL_HOME to the extracted command-line-tools}"
PROJECT="${PROJECT:-$PWD/build}"
[ -f "$PROJECT/hvigorfile.ts" ] || { echo "not an app source tree: $PROJECT" >&2; exit 1; }

export PATH="$TOOL_HOME/bin:$TOOL_HOME/tool/node/bin:$TOOL_HOME/sdk/default/openharmony/toolchains:$PATH"
export DEVECO_SDK_HOME="$TOOL_HOME/sdk"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"

cd "$PROJECT"

# The IEC HAR builds these itself; duplicates in entry/libs make ProcessLibs fail.
rm -f entry/libs/arm64-v8a/libiec_server.so \
      entry/libs/arm64-v8a/libncploader.so \
      entry/libs/arm64-v8a/libdsh_terminal.so

ohpm install --all
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

out="entry/build/default/outputs/default/entry-default-unsigned.hap"
[ -f "$out" ] || { echo "missing $out" >&2; exit 1; }
ls -lh "$out"
echo "SHA256: $(sha256sum "$out" | awk '{print $1}')"
