#!/usr/bin/env bash
# Apply the DSH HOS patches to the vendored app/ source.
#   patch-project.sh <project-dir> [bundle-name] [app-name]
set -euo pipefail

PROJECT="${1:?project dir}"
BUNDLE="${2:-com.dsh.hos}"
APP_NAME="${3:-DSH HOS}"
VERSION_NAME="${VERSION_NAME:-0.2.2-rc.5-dshhos.1}"
VERSION_CODE="${VERSION_CODE:-8}"
[ -f "$PROJECT/hvigorfile.ts" ] || { echo "not an app source tree: $PROJECT" >&2; exit 1; }

python3 - "$PROJECT" "$BUNDLE" "$APP_NAME" "$VERSION_NAME" "$VERSION_CODE" <<'PY'
import json, re, sys
from pathlib import Path

project, bundle, app_name, version_name, version_code = sys.argv[1:6]
root = Path(project)

def edit(path, fn):
    p = root / path
    if not p.exists():
        print(f"  skip missing {path}")
        return
    p.write_text(fn(p.read_text()), encoding="utf-8")
    print(f"  patched {path}")

# 1) Startup gate: DSH 0.2.2 renders an EMPTY data-conversation-session
# attribute. The upstream check required a non-empty value and never dismissed
# the splash screen.
def fix_index(s):
    s = s.replace(
        "var ready=!!s&&(s.getAttribute('data-conversation-session')||'').length>0;",
        "var ready=!!s;",
    )
    return s
edit('entry/src/main/ets/pages/Index.ets', fix_index)

# 2) bundle name / version
def fix_app(s):
    s = re.sub(r'"bundleName"\s*:\s*"[^"]*"', f'"bundleName": "{bundle}"', s, count=1)
    s = re.sub(r'"versionCode"\s*:\s*\d+', f'"versionCode": {version_code}', s, count=1)
    s = re.sub(r'"versionName"\s*:\s*"[^"]*"', f'"versionName": "{version_name}"', s, count=1)
    return s
edit('AppScope/app.json5', fix_app)


# 3) app label
def fix_label(s):
    d = json.loads(s)
    for row in d.get("string", []):
        if row.get("name") == "app_name":
            row["value"] = app_name
    return json.dumps(d, ensure_ascii=False, indent=2) + "\n"
edit('AppScope/resources/base/element/string.json', fix_label)

# 4) module description
def fix_desc(s):
    d = json.loads(s)
    for row in d.get("string", []):
        if row.get("name") == "module_desc":
            row["value"] = f"{app_name} · 鸿蒙原生"
    return json.dumps(d, ensure_ascii=False, indent=2) + "\n"
edit('entry/src/main/resources/base/element/string.json', fix_desc)

# 5) build profile: SDK 5.1 (API 18), unsigned
profile = root / 'build-profile.json5'
example = root / 'build-profile.example.json5'
if not profile.exists() and example.exists():
    profile.write_text(example.read_text(), encoding="utf-8")
def fix_profile(s):
    s = re.sub(r'"targetSdkVersion"\s*:\s*"[^"]*"', '"targetSdkVersion": "5.1.0(18)"', s, count=1)
    s = re.sub(r'"compatibleSdkVersion"\s*:\s*"[^"]*"', '"compatibleSdkVersion": "5.1.0(18)"', s, count=1)
    s = re.sub(r'\n\s*"signingConfig"\s*:\s*"[^"]*",?', '', s)
    return s
if profile.exists():
    profile.write_text(fix_profile(profile.read_text()), encoding="utf-8")
    print("  patched build-profile.json5")

# 6) hvigor model version
for f in ('hvigor/hvigor-config.json5', 'oh-package.json5'):
    edit(f, lambda s: s.replace('"modelVersion": "6.1.1"', '"modelVersion": "5.1.0"'))

# 7) The IEC HAR builds these three itself; duplicates in entry/libs make
# ProcessLibs fail with "Duplicated files found in module entry".
for lib in ('libiec_server.so', 'libncploader.so', 'libdsh_terminal.so'):
    p = root / 'entry/libs/arm64-v8a' / lib
    if p.exists():
        p.unlink()
        print(f"  removed duplicate {lib}")
PY

echo "patched: bundle=$BUNDLE app=$APP_NAME version=$VERSION_NAME($VERSION_CODE)"
