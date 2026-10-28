"""Long running production HAP test with synthetic output and aggregate metrics."""
import json
import math
import os
import re
import subprocess
import time
from pathlib import Path
import smoke as ui

REPORT = Path(os.environ.get('HT_REPORT_DIR', str(Path(__file__).resolve().parents[2] / '.runtime/soak')))
DURATION = int(os.environ.get('HT_SOAK_SECONDS', '600'))
assert 30 <= DURATION <= 3600
REPORT.mkdir(parents=True, exist_ok=True)


def device(*args):
    return subprocess.check_output([ui.HDC, 'shell', *args], timeout=15).decode(errors='replace')


def memory():
    output = device('ps', '-A', '-o', 'PID,NAME')
    processes = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].startswith('com.nickitclaw.hterminal'):
            status = device('cat', '/proc/' + parts[0] + '/status')
            fields = dict(re.findall(r'^(VmRSS|RssAnon|Threads):\s+(\d+)', status, re.M))
            processes.append({'pid': int(parts[0]), 'name': parts[1], **{k: int(v) for k, v in fields.items()}})
    assert processes and all('VmRSS' in p for p in processes), 'memory evidence unavailable'
    return {'rssKiB': sum(p['VmRSS'] for p in processes), 'anonKiB': sum(p['RssAnon'] for p in processes),
            'threads': sum(p['Threads'] for p in processes), 'processes': processes}


def diagnostics():
    ui.click(ui.by_id(ui.layout(), 'terminal-tools'))
    entries = ui.wait(lambda e: ui.by_id(e, 'session-diagnostics'))
    ui.click(ui.by_id(entries, 'session-diagnostics'))
    entries = ui.wait(lambda e: ui.find(e, '会话诊断'))
    item = next(a for a in entries if a.get('type') == 'Text' and a.get('text', '').startswith('{"connectionEpoch"'))
    result = json.loads(item['text'])
    ui.click(ui.find(entries, '关闭诊断'))
    ui.click(ui.by_id(ui.layout(), 'terminal-tools-close'))
    assert result['state'] == 'OPEN' and result['native'] is not None, result
    native = result['native']
    assert native['peakUnackedBytes'] <= 256 * 1024, result
    assert native['peakInputBytes'] <= 65536, result
    assert native['peakReceiveBytes'] <= 2359296, result
    assert result['pausedOutputBytes'] <= 256 * 1024, result
    return result


def timed_key(identifier, expected):
    entries = ui.wait(lambda e: ui.by_id(e, 'key-' + identifier) and ui.by_id(e, 'key-' + identifier).get('enabled') == 'true')
    item = ui.by_id(entries, 'key-' + identifier)
    left, top, right, bottom = map(int, re.findall(r'-?\d+', item['bounds']))
    before = len((ui.WORK / 'server.log').read_text().splitlines())
    started = time.time() * 1000
    ui.call('shell', 'uitest', 'uiInput', 'click', str((left + right) // 2), str((top + bottom) // 2))
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        lines = (ui.WORK / 'server.log').read_text().splitlines()[before:]
        matches = [line.split() for line in lines if line.startswith('TIMING ') and line.split()[3] == expected]
        if matches:
            return max(0, int(matches[-1][2]) - started)
        time.sleep(.02)
    raise AssertionError('input was not delivered during continuous output')


def run_case(count):
    ui.connect(username='soak')
    epochs = {1: diagnostics()['connectionEpoch']}
    for index in range(count - 1):
        ui.click(ui.by_id(ui.layout(), 'new-session'))
        ui.connect(username='soak')
        epochs[index + 2] = diagnostics()['connectionEpoch']
    # Allow the scrollback and all hidden SSH windows to reach steady occupancy.
    print(f'SOAK: {count} session(s), warming scrollback/window buffers', flush=True)
    time.sleep(30)
    samples, latencies = [], []
    started = time.monotonic()
    iteration = 0
    while time.monotonic() - started < DURATION:
        active = iteration % count + 1
        if count > 1:
            ui.click(ui.by_id(ui.layout(), 'tab-session-' + str(active)))
        ui.wait(lambda e: ui.by_id(e, 'key-r') and ui.by_id(e, 'key-r').get('enabled') == 'true')
        latencies.append(timed_key('r', 'cg=='))
        current = diagnostics()
        samples.append({'elapsed': round(time.monotonic() - started, 2), 'session': active,
                        'memory': memory(), 'diagnostics': current})
        (REPORT / f'soak-{count}-samples.json').write_text(json.dumps(samples, indent=2))
        # Exercise real resize while output and hidden-session backpressure continue.
        if iteration % 2 == 0:
            ui.click(ui.find(ui.layout(), '布局', 'Button'))
        if iteration % 3 == 0:
            ui.click(ui.by_id(ui.layout(), 'key-ctrl'))
            latencies.append(timed_key('c', 'Aw=='))
            timed_key('r', 'cg==')
        iteration += 1
        print(f'SOAK: {count} session(s), elapsed={round(time.monotonic() - started)}s, '
              f'RSS={samples[-1]["memory"]["rssKiB"]}KiB, '
              f'peak receive={current["native"]["peakReceiveBytes"]}', flush=True)
        time.sleep(15)
    # Visit every hidden tab to ensure buffered output parses and the same epoch remains usable.
    for active in range(1, count + 1):
        if count > 1:
            ui.click(ui.by_id(ui.layout(), 'tab-session-' + str(active)))
        value = diagnostics()
        assert value['connectionEpoch'] == epochs[active] and value['native']['outputBytes'] > 32768, value
    ordered = sorted(latencies)
    tail = samples[len(samples) // 2:]
    first, last = tail[0], tail[-1]
    slope = (last['memory']['anonKiB'] - first['memory']['anonKiB']) / max(1, last['elapsed'] - first['elapsed'])
    summary = {'sessions': count, 'durationSeconds': round(time.monotonic() - started, 2), 'samples': len(samples),
               'inputDispatchToFixtureP95Ms': round(ordered[math.ceil(.95 * len(ordered)) - 1], 2),
               'tailAnonKiBPerSecond': round(slope, 2), 'peakRssKiB': max(s['memory']['rssKiB'] for s in samples),
               'finalThreads': samples[-1]['memory']['threads'],
               'notes': 'Emulator only; input timing includes hdc dispatch and SSH. RSS sums shared pages. This is not a physical touch latency measurement.'}
    (REPORT / f'soak-{count}-summary.json').write_text(json.dumps(summary, indent=2))
    # Detect substantial unbounded growth; report all samples for finer trend review.
    assert slope < 128, summary
    print('PASS: production HAP soak ' + json.dumps(summary), flush=True)


def run():
    counts = [int(value) for value in os.environ.get('HT_SOAK_COUNTS', '1,4').split(',')]
    assert counts and all(value in [1, 4] for value in counts)
    for count in counts:
        run_case(count)
        ui.call('shell', 'aa', 'force-stop', 'com.nickitclaw.hterminal')
        ui.call('shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.nickitclaw.hterminal')
        ui.wait(lambda e: ui.find(e, '连接 SSH 服务器'))
