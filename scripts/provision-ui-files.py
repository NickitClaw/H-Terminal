#!/usr/bin/env python3
"""Provision disposable keys through the system save picker; restore normal HAP."""
import json
import os
import re
import signal
import subprocess
import time
import uuid
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
work = Path(os.environ['HT_UI_WORK'])
deveco = Path(os.environ.get('DEVECO_HOME', '/Applications/DevEco-Studio.app/Contents'))
hdc = str(deveco / 'sdk/default/openharmony/toolchains/hdc')
ability = root / 'entry/src/main/ets/entryability/EntryAbility.ets'
probe = ability.parent / 'testing/DeviceProbe.ets'
original = ability.read_bytes()
assert not probe.exists() and b'verifyDeviceStorage' not in original
marker = 'HT_PROBE_' + uuid.uuid4().hex
cleanup = os.environ.get('HT_CLEAN_UI_FILES') == '1'
manifest = work / 'picker-files.json'
names = ['HT-ui-' + marker[-8:] + '-' + kind + '.pem' for kind in ['plain', 'encrypted', 'invalid']]
contents = [] if cleanup else [(work / 'identity').read_text(), (work / 'encrypted-identity').read_text(), 'invalid private key']
remove = json.loads(manifest.read_text())['uris'] if cleanup else []


def interrupted(_signum, _frame):
    raise KeyboardInterrupt()


signal.signal(signal.SIGTERM, interrupted)


def run(args):
    try:
        return subprocess.check_output(args, cwd=root, stderr=subprocess.STDOUT, timeout=120).decode(errors='replace')
    except subprocess.CalledProcessError as error:
        (work / 'provision-command.log').write_bytes(error.output)
        raise


def save_picker():
    run([hdc, 'shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/hterminal-ui-layout.json'])
    run([hdc, 'file', 'recv', '/data/local/tmp/hterminal-ui-layout.json', str(work / 'save-layout.json')])
    items = []
    def walk(x):
        if isinstance(x, dict):
            a = x.get('attributes', {})
            if a.get('text') in ['保存', 'Download'] or a.get('id') == 'dialog_confirm':
                items.append(a)
            for v in x.values():
                walk(v)
        elif isinstance(x, list):
            for v in x:
                walk(v)
    walk(json.loads((work / 'save-layout.json').read_text()))
    if items:
        a = next((a for a in items if a.get('id') == 'dialog_confirm' or a.get('text') == '保存'), items[0])
        left, top, right, bottom = map(int, re.findall(r'-?\d+', a['bounds']))
        run([hdc, 'shell', 'uitest', 'uiInput', 'click', str((left + right) // 2), str((top + bottom) // 2)])
        time.sleep(.4)


try:
    text = (root / 'tests/device/provision-files.ets').read_text()
    for key, value in [('__HT_PROBE_MARKER__', marker), ('__HT_CONTENTS__', json.dumps(contents)),
                       ('__HT_NAMES__', json.dumps(names)), ('__HT_REMOVE__', json.dumps(remove))]:
        text = text.replace(key, value)
    probe.parent.mkdir(parents=True, exist_ok=True)
    probe.write_text(text)
    source = original.decode().replace('import { UIAbility }', "import { verifyDeviceStorage } from './testing/DeviceProbe';\nimport { UIAbility }")
    ability.write_text(source.replace('windowStage.loadContent(', 'verifyDeviceStorage(this.context);\n    windowStage.loadContent(', 1))
    for args in [['./scripts/assemble-debug.sh'], ['./scripts/sign-debug.sh', 'entry/build/default/outputs/default/entry-default-unsigned.hap'],
                 [hdc, 'install', '-r', '.runtime/signing/H-Terminal-signed.hap'],
                 [hdc, 'shell', 'aa', 'force-stop', 'com.nickitclaw.hterminal'],
                 [hdc, 'shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.nickitclaw.hterminal']]:
        run(args)
    print('UI fixture: waiting for the system save picker', flush=True)
    uris = []
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        log = run([hdc, 'shell', 'hilog', '-x', '-T', 'HTDeviceProbe'])
        uris = list(dict.fromkeys(re.findall(re.escape(marker) + r' URI (\S+)', log)))
        if not cleanup and uris:
            manifest.write_text(json.dumps({'names': names, 'uris': uris}))
        assert marker + ' FAIL' not in log, next((line for line in log.splitlines() if marker + ' FAIL' in line), '')
        if marker + ' PASS' in log:
            break
        if not cleanup:
            save_picker()
        time.sleep(.5)
    else:
        raise AssertionError('system save picker did not complete; inspect save-layout.json')
    if not cleanup:
        assert len(uris) == len(names)
        manifest.write_text(json.dumps({'names': names, 'uris': uris}))
    print('PASS: disposable picker files ' + ('cleared' if cleanup else 'saved'), flush=True)
finally:
    ability.write_bytes(original)
    probe.unlink(missing_ok=True)
    run(['./scripts/assemble-debug.sh', '--clean'])
    with zipfile.ZipFile(root / 'entry/build/default/outputs/default/entry-default-unsigned.hap') as package:
        assert all(marker.encode() not in package.read(n) for n in package.namelist() if n.endswith(('.abc', '.map')))
    run(['./scripts/sign-debug.sh', 'entry/build/default/outputs/default/entry-default-unsigned.hap'])
    run([hdc, 'install', '-r', '.runtime/signing/H-Terminal-signed.hap'])
