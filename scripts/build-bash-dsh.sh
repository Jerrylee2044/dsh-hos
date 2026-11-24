#!/usr/bin/env bash
# 从 GNU Bash 5.3 上游源码构建 DSH HOS 自研入口的 libbash.so。
# 用法: OHOS_SDK=... BASH_SRC=... bash scripts/build-bash-dsh.sh
set -euo pipefail
: "${OHOS_SDK:?set OHOS_SDK}"
: "${BASH_SRC:?set BASH_SRC to an extracted bash-5.3 source tree}"
OUT=${OUT:-$(pwd)/out}
CLANG="$OHOS_SDK/native/llvm/bin/clang"
SYSROOT="$OHOS_SDK/native/sysroot"
BUILD="$OUT/bash-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
cp -a "$BASH_SRC" "$BUILD/bash"
cd "$BUILD/bash"
find . -name '*.o' -delete; rm -f bash
printf '#!/bin/sh\nexec "%s" --target=aarch64-linux-ohos --sysroot="%s" -fuse-ld=lld "$@"\n' "$CLANG" "$SYSROOT" > "$BUILD/cc"
chmod +x "$BUILD/cc"
CC="$BUILD/cc" CC_FOR_BUILD=gcc CFLAGS_FOR_BUILD=-O2 \
  CFLAGS='-O2 -fPIC' ./configure --host=aarch64-linux-ohos --build=x86_64-pc-linux-gnu \
  --without-bash-malloc --disable-nls --disable-rpath
make -j"${JOBS:-6}" CC_FOR_BUILD='gcc -std=gnu17'
rm -f shell.o bash
make shell.o CC_FOR_BUILD='gcc -std=gnu17' CFLAGS='-O2 -fPIC -Dmain=dsh_bash_main'
make bash CC_FOR_BUILD='gcc -std=gnu17' LDFLAGS='-shared -Wl,-soname,libbash.so'
mkdir -p "$OUT"
cp bash "$OUT/libbash.so"
"$OHOS_SDK/native/llvm/bin/llvm-nm" -D "$OUT/libbash.so" | grep ' dsh_bash_main$'
