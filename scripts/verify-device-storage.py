#!/usr/bin/env python3
"""Inject a disposable device probe, verify real HUKS/NAPI, then restore and rebuild."""
import json
import os
import subprocess
import time
import uuid
import signal
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
deveco = Path(os.environ.get('DEVECO_HOME', '/Applications/DevEco-Studio.app/Contents'))
hdc = str(deveco / 'sdk/default/openharmony/toolchains/hdc')
node = str(deveco / 'tools/node/bin/node')
ability = root / 'entry/src/main/ets/entryability/EntryAbility.ets'
probe = root / 'entry/src/main/ets/entryability/testing/DeviceProbe.ets'
original = ability.read_bytes()
assert not probe.exists() and b'verifyDeviceStorage' not in original, 'a previous device probe requires cleanup'
marker = 'HT_PROBE_' + uuid.uuid4().hex
runtime = root / '.runtime/device-storage'
runtime.mkdir(parents=True, exist_ok=True)
(runtime / 'EntryAbility.original').write_bytes(original)


def interrupted(_signum, _frame):
    raise KeyboardInterrupt()


signal.signal(signal.SIGTERM, interrupted)


def run(args, name):
    with (runtime / (name + '.log')).open('w') as log:
        subprocess.run(args, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)


try:
    keys = json.loads(subprocess.check_output([node, '-e',
        "const {utils}=require('./terminal/node_modules/ssh2');"
        "process.stdout.write(JSON.stringify([utils.generateKeyPairSync('ed25519').private,"
        "utils.generateKeyPairSync('ed25519',{passphrase:'fixture-passphrase',cipher:'aes256-ctr'}).private]));"], cwd=root))
    text = (root / 'tests/device/credential-probe.ets').read_text()
    text = text.replace('__HT_PROBE_MARKER__', marker).replace('__HT_PROBE_KEY__', json.dumps(keys[0]))
    text = text.replace('__HT_PROBE_ENCRYPTED_KEY__', json.dumps(keys[1]))
    probe.parent.mkdir(parents=True, exist_ok=True)
    probe.write_text(text)
    source = original.decode().replace("import { UIAbility }", "import { verifyDeviceStorage } from './testing/DeviceProbe';\nimport { UIAbility }")
    source = source.replace('windowStage.loadContent(', 'verifyDeviceStorage(this.context);\n    windowStage.loadContent(', 1)
    ability.write_text(source)
    run(['./scripts/assemble-debug.sh'], 'build-probe')
    run(['./scripts/sign-debug.sh', 'entry/build/default/outputs/default/entry-default-unsigned.hap'], 'sign-probe')
    run([hdc, 'install', '-r', '.runtime/signing/H-Terminal-signed.hap'], 'install-probe')
    run([hdc, 'shell', 'aa', 'force-stop', 'com.nickitclaw.hterminal'], 'stop-probe')
    run([hdc, 'shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.nickitclaw.hterminal'], 'start-probe')
    deadline = time.monotonic() + 40
    passed = False
    while time.monotonic() < deadline:
        output = subprocess.check_output([hdc, 'shell', 'hilog', '-x', '-T', 'HTDeviceProbe'], timeout=10).decode(errors='replace')
        if marker + ' FAIL' in output:
            detail = next(line for line in output.splitlines() if marker + ' FAIL' in line)
            raise AssertionError('real HUKS/NAPI device probe failed: ' + detail)
        if marker + ' PASS' in output:
            passed = True
            break
        time.sleep(.5)
    assert passed, 'device probe did not complete'
    print('PASS: actual NAPI key inspection, encrypted Ed25519 passphrase, HUKS AES-GCM, restart and tamper rejection')
finally:
    ability.write_bytes(original)
    if probe.exists():
        probe.unlink()
    # Always restore the production artifact as well as its source.
    run(['./scripts/assemble-debug.sh', '--clean'], 'build-restored')
    artifact = root / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
    with zipfile.ZipFile(artifact) as package:
        assert all(marker.encode() not in package.read(name) for name in package.namelist()
                   if name.endswith(('.abc', '.map'))), 'temporary probe remains in the restored artifact'
