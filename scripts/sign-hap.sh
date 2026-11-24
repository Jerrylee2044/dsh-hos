#!/usr/bin/env bash
# 用 AGC 调试证书/Profile 签一个 HAP，并校验。
#
# 用法：
#   KEY_ALIAS=... APP_CERT=... PROFILE=... KEYSTORE=... \
#   bash sign-hap.sh <input.hap> <output.hap>
#
# 口令不落盘：未设置 KEY_PWD / STORE_PWD 时交互读取。
# 依赖：java、hap-sign-tool.jar（DevEco SDK 或 OpenHarmony toolchains 自带）。
set -euo pipefail

in="${1:?input.hap}"
out="${2:?output.hap}"
[ -f "$in" ] || { echo "no such file: $in" >&2; exit 1; }

: "${KEY_ALIAS:?set KEY_ALIAS}"
: "${APP_CERT:?set APP_CERT (debug .cer)}"
: "${PROFILE:?set PROFILE (debug .p7b)}"
: "${KEYSTORE:?set KEYSTORE (.p12)}"
for f in "$APP_CERT" "$PROFILE" "$KEYSTORE"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

if [ -z "${HAP_SIGN_TOOL:-}" ]; then
  for base in "${TOOL_HOME:-}" "${DEVECO_HOME:-}" "${OHOS_SDK:-}" "$HOME/deveco-studio" /opt/deveco-studio; do
    [ -n "$base" ] || continue
    HAP_SIGN_TOOL="$(find "$base" -name 'hap-sign-tool.jar' 2>/dev/null | head -n1 || true)"
    [ -n "$HAP_SIGN_TOOL" ] && break
  done
fi
[ -n "${HAP_SIGN_TOOL:-}" ] || { echo "hap-sign-tool.jar not found; set HAP_SIGN_TOOL" >&2; exit 1; }
command -v java >/dev/null || { echo "java not found" >&2; exit 1; }

if [ "${EMPTY_PWD:-0}" = "1" ]; then
  KEY_PWD=""
  STORE_PWD=""
else
  if [ -z "${KEY_PWD:-}" ]; then
    read -r -s -p "key password: " KEY_PWD; echo
  fi
  if [ -z "${STORE_PWD:-}" ]; then
    read -r -s -p "keystore password: " STORE_PWD; echo
  fi
fi

pwd_args=()
if [ "${EMPTY_PWD:-0}" != "1" ]; then
  pwd_args=(-keyPwd "$KEY_PWD" -keystorePwd "$STORE_PWD")
fi

java -jar "$HAP_SIGN_TOOL" sign-app \
  -keyAlias "$KEY_ALIAS" \
  -signAlg "SHA256withECDSA" \
  -mode "localSign" \
  -appCertFile "$APP_CERT" \
  -profileFile "$PROFILE" \
  -inFile "$in" \
  -keystoreFile "$KEYSTORE" \
  -outFile "$out" \
  "${pwd_args[@]}"

java -jar "$HAP_SIGN_TOOL" verify-app \
  -inFile "$out" \
  -outCertChain "${out}.cer" \
  -outProfile "${out}.p7b"

echo "OK: $out"
echo "Install: hdc install -r \"$out\""
