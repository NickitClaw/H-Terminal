#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEVECO=${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}
SDK_TOOLS="$DEVECO/sdk/default/openharmony/toolchains"
JAVA="$DEVECO/jbr/Contents/Home/bin/java"
HDC="$SDK_TOOLS/hdc"
INPUT=${1:?"usage: scripts/sign-debug.sh <unsigned.hap> [signed.hap]"}
OUTPUT=${2:-"$ROOT/.runtime/signing/H-Terminal-signed.hap"}
WORK="$ROOT/.runtime/signing"
mkdir -p "$WORK"

UDID_OUTPUT=$("$HDC" shell bm get -u)
UDID=${UDID_OUTPUT##*$'\n'}
if [[ ! "$UDID" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  echo "Unable to obtain emulator UDID" >&2
  exit 1
fi

python3 - "$SDK_TOOLS/lib/UnsgnedDebugProfileTemplate.json" "$SDK_TOOLS/lib/OpenHarmonyProfileDebug.pem" "$WORK" "$UDID" <<'PY'
import json
import pathlib
import re
import sys
import time
import uuid

template_path, chain_path, output_dir, udid = sys.argv[1:]
out = pathlib.Path(output_dir)
with open(template_path, "r", encoding="utf-8") as source:
    profile = json.load(source)
now = int(time.time())
profile["uuid"] = str(uuid.uuid4())
profile["validity"] = {"not-before": now - 300, "not-after": now + 30 * 24 * 60 * 60}
profile["bundle-info"]["bundle-name"] = "com.nickitclaw.hterminal"
profile["debug-info"]["device-ids"] = [udid]
(out / "profile.json").write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
leaf = profile["bundle-info"]["development-certificate"]
with open(chain_path, "r", encoding="utf-8") as source:
    text = source.read()
blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----\n?", text, re.S)
if len(blocks) < 2:
    raise RuntimeError("SDK public CA chain is incomplete")
chain = leaf + "\n" + blocks[1] + "\n" + blocks[0] + "\n"
(out / "app-chain.pem").write_text(chain, encoding="utf-8")
PY

"$JAVA" -jar "$SDK_TOOLS/lib/hap-sign-tool.jar" sign-profile \
  -mode localSign \
  -keyAlias "openharmony application profile debug" \
  -keyPwd 123456 \
  -profileCertFile "$SDK_TOOLS/lib/OpenHarmonyProfileDebug.pem" \
  -inFile "$WORK/profile.json" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$SDK_TOOLS/lib/OpenHarmony.p12" \
  -keystorePwd 123456 \
  -outFile "$WORK/profile.p7b"

"$JAVA" -jar "$SDK_TOOLS/lib/hap-sign-tool.jar" sign-app \
  -mode localSign \
  -keyAlias "OpenHarmony Application Release" \
  -keyPwd 123456 \
  -appCertFile "$WORK/app-chain.pem" \
  -profileFile "$WORK/profile.p7b" \
  -inFile "$INPUT" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$SDK_TOOLS/lib/OpenHarmony.p12" \
  -keystorePwd 123456 \
  -outFile "$OUTPUT" \
  -compatibleVersion 26 \
  -signCode 1

printf '%s\n' "$OUTPUT"
