#!/usr/bin/env bash
# Generate a debug keystore + CSR for AGC (HarmonyOS developer center).
#
#   TOOL_HOME=/path/to/command-line-tools bash scripts/make-csr.sh
#
# Environment:
#   KEY_ALIAS     default dsh-debug
#   OUT_DIR       default ./signing
#   KEYSTORE_PWD  optional; otherwise prompt
#   HAP_SIGN_TOOL optional; otherwise find in TOOL_HOME
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_ALIAS="${KEY_ALIAS:-dsh-debug}"
OUT_DIR="${OUT_DIR:-$ROOT/signing}"
mkdir -p "$OUT_DIR"

if [ -z "${HAP_SIGN_TOOL:-}" ]; then
  for base in "${TOOL_HOME:-}" "$ROOT"; do
    [ -n "$base" ] || continue
    HAP_SIGN_TOOL="$(find "$base" -name 'hap-sign-tool.jar' 2>/dev/null | head -n1 || true)"
    [ -n "$HAP_SIGN_TOOL" ] && break
  done
fi
[ -n "${HAP_SIGN_TOOL:-}" ] || { echo "hap-sign-tool.jar not found; set HAP_SIGN_TOOL" >&2; exit 1; }
command -v java >/dev/null || { echo "java not found" >&2; exit 1; }

if [ -z "${KEYSTORE_PWD:-}" ]; then
  read -r -s -p "keystore password (>= 6 chars): " KEYSTORE_PWD; echo
  read -r -s -p "repeat: " again; echo
  [ "$KEYSTORE_PWD" = "$again" ] || { echo "passwords differ" >&2; exit 1; }
fi
[ ${#KEYSTORE_PWD} -ge 6 ] || { echo "password must be at least 6 chars" >&2; exit 1; }

p12="$OUT_DIR/$KEY_ALIAS.p12"
csr="$OUT_DIR/$KEY_ALIAS.csr"

if [ ! -f "$p12" ]; then
  java -jar "$HAP_SIGN_TOOL" generate-keypair \
    -keyAlias "$KEY_ALIAS" -keyAlg ECC -keySize NIST-P-256 \
    -keystoreFile "$p12" -keystorePwd "$KEYSTORE_PWD" -keyPwd "$KEYSTORE_PWD"
  chmod 600 "$p12"
else
  echo "reuse existing $p12"
fi

java -jar "$HAP_SIGN_TOOL" generate-csr \
  -keyAlias "$KEY_ALIAS" \
  -subject "C=CN,O=DSH HOS,OU=Debug,CN=$KEY_ALIAS" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$p12" -keystorePwd "$KEYSTORE_PWD" -keyPwd "$KEYSTORE_PWD" \
  -outFile "$csr"

echo
echo "keystore: $p12"
echo "CSR:      $csr  (upload this to AGC -> 证书 -> 新增证书 -> 调试证书)"
echo "Keep the keystore and its password; you need them for signing."
