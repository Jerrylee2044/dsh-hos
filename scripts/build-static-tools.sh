#!/usr/bin/env bash
# Build the non-PIE x86_64 tools used by the QEMU guest.
# Output: app/entry/src/main/resources/rawfile/qemu/{git,rg}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/entry/src/main/resources/rawfile/qemu"
WORK="${WORK:-/var/tmp/dsh-static-tools}"
mkdir -p "$OUT" "$WORK"

: "${GIT_VERSION:=2.47.1}"
: "${RG_VERSION:=14.1.1}"

if [ ! -x "$OUT/git" ]; then
  cd "$WORK"
  [ -f "git-$GIT_VERSION.tar.xz" ] || curl -L --retry 3 -o "git-$GIT_VERSION.tar.xz" \
    "https://mirrors.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.xz"
  rm -rf "git-$GIT_VERSION" && tar -xJf "git-$GIT_VERSION.tar.xz"
  cd "git-$GIT_VERSION"
  make configure >/dev/null
  ./configure --prefix="$WORK/git-static" CFLAGS='-O2 -static -no-pie' LDFLAGS='-static -no-pie' \
    NO_OPENSSL=1 NO_CURL=1 NO_EXPAT=1 NO_PERL=1 NO_TCLTK=1 NO_GETTEXT=1 NO_PYTHON=1 >/dev/null
  make -j"$(nproc)" CFLAGS='-O2 -static -no-pie -std=gnu17' LDFLAGS='-static -no-pie' \
    NO_OPENSSL=1 NO_CURL=1 NO_EXPAT=1 NO_PERL=1 NO_TCLTK=1 NO_GETTEXT=1 NO_PYTHON=1 >/dev/null
  cp git "$OUT/git"
fi

if [ ! -x "$OUT/rg" ]; then
  cd "$WORK"
  [ -f "ripgrep-$RG_VERSION.tar.gz" ] || curl -L --retry 3 -o "ripgrep-$RG_VERSION.tar.gz" \
    "https://github.com/BurntSushi/ripgrep/archive/refs/tags/$RG_VERSION.tar.gz"
  rm -rf "ripgrep-$RG_VERSION" && tar -xzf "ripgrep-$RG_VERSION.tar.gz"
  cd "ripgrep-$RG_VERSION"
  RUSTFLAGS='-C target-feature=+crt-static -C relocation-model=static' \
    cargo build --release --target x86_64-unknown-linux-gnu >/dev/null
  strip target/x86_64-unknown-linux-gnu/release/rg
  cp target/x86_64-unknown-linux-gnu/release/rg "$OUT/rg"
fi

echo "tools: $OUT"
file "$OUT/git" "$OUT/rg"
