#!/usr/bin/env python3
"""Record reproducible, explicit validation results and narrowly scoped evidence."""
import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT).decode().strip()


def source_digest():
    names = set(subprocess.check_output(['git', 'ls-files', '-c', '-o', '--exclude-standard', '-z'], cwd=ROOT).split(b'\0'))
    digest = hashlib.sha256()
    for raw in sorted(n for n in names if n):
        path = ROOT / os.fsdecode(raw)
        if path.is_file():
            digest.update(raw + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()


def version(command):
    try:
        return subprocess.check_output(command, stderr=subprocess.STDOUT, timeout=10).decode().strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError):
        return 'unavailable'


class Reporter:
    def __init__(self, directory, mode, steps):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.report = {'mode': mode, 'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       'commit': git('rev-parse', 'HEAD'), 'sourceSha256': source_digest(),
                       'dirty': bool(git('status', '--porcelain')), 'host': platform.platform(),
                       'node': version(['node', '--version']), 'python': platform.python_version(),
                       'status': 'running', 'steps': [{'name': name, 'status': 'not_run'} for name, _ in steps]}
        self.persist()

    def persist(self):
        target = self.directory / 'report.json'
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(self.report, indent=2, ensure_ascii=False))
        temporary.replace(target)
        rows = ['# H-Terminal validation', '', f"Status: **{self.report['status']}**",
                f"Commit: `{self.report['commit']}`", f"Source: `{self.report['sourceSha256']}`", '',
                '| Check | Result | Seconds | Log |', '| --- | --- | ---: | --- |']
        for step in self.report['steps']:
            log = f"[{step['name']}.log]({step['name']}.log)" if 'elapsedSeconds' in step else ''
            rows.append(f"| {step['name']} | {step['status']} | {step.get('elapsedSeconds', '')} | {log} |")
        rows.extend(['', 'Only explicitly executed checks are marked passed. Logs exclude private-key PEM blocks.',
                     'Emulator measurements do not establish physical-device performance.'])
        (self.directory / 'report.md').write_text('\n'.join(rows) + '\n')

    def run(self, index, command, environment=None):
        step = self.report['steps'][index]
        step['status'] = 'running'
        self.persist()
        print('VERIFY: ' + step['name'], flush=True)
        started = time.monotonic()
        redacting = False
        env = dict(os.environ, HT_REPORT_DIR=str(self.directory))
        if environment:
            env.update(environment)
        try:
            with (self.directory / (step['name'] + '.log')).open('w') as log:
                process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT, text=True, errors='replace')
                try:
                    for line in process.stdout:
                        if re.search(r'-----BEGIN .*PRIVATE KEY-----', line):
                            redacting = True
                            log.write('[private-key PEM redacted]\n')
                        if not redacting:
                            log.write(line)
                            log.flush()
                            print(line, end='', flush=True)
                        if re.search(r'-----END .*PRIVATE KEY-----', line):
                            redacting = False
                    code = process.wait()
                except BaseException:
                    process.terminate()
                    try:
                        process.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                    raise
                finally:
                    process.stdout.close()
        except OSError as error:
            code = 127
            (self.directory / (step['name'] + '.log')).write_text(str(error))
        step.update(status='passed' if code == 0 else 'failed', exitCode=code,
                    elapsedSeconds=round(time.monotonic() - started, 2))
        self.persist()
        return code == 0

    def finish(self, passed):
        self.report['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.report['finalSourceSha256'] = source_digest()
        self.report['sourceChanged'] = self.report['finalSourceSha256'] != self.report['sourceSha256']
        self.report['status'] = 'passed' if passed and not self.report['sourceChanged'] else 'failed'
        artifact = ROOT / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
        if artifact.exists():
            self.report['artifactSha256'] = hashlib.sha256(artifact.read_bytes()).hexdigest()
        self.persist()
        return self.report['status'] == 'passed'


def capture_failure(directory, deveco, since):
    hdc = str(deveco / 'sdk/default/openharmony/toolchains/hdc')
    if not Path(hdc).exists():
        return
    for command in [[hdc, 'shell', 'snapshot_display', '-f', '/data/local/tmp/hterminal-verify-failure.png'],
                    [hdc, 'file', 'recv', '/data/local/tmp/hterminal-verify-failure.png', str(directory / 'failure.png')],
                    [hdc, 'shell', 'rm', '-f', '/data/local/tmp/hterminal-verify-failure.png']]:
        try:
            subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        except (OSError, subprocess.SubprocessError):
            pass
    # Copy only known synthetic-test evidence. Never archive the full .runtime tree.
    failure = ROOT / '.runtime/last-ui-failure'
    for name in ['layout.json', 'save-layout.json', 'server.log', 'auth-server.log', 'picker-cleanup.log']:
        if (failure / name).exists() and (failure / name).stat().st_mtime >= since:
            shutil.copyfile(failure / name, directory / ('ui-failure-' + name))


def plan(mode):
    steps = [('npm-ci', ['npm', 'ci', '--prefix', 'terminal', '--ignore-scripts', '--no-audit', '--no-fund']),
             ('unit', ['npm', '--prefix', 'terminal', 'test']),
             ('verification-tests', [sys.executable, '-m', 'unittest', 'discover', '-s', 'tests/scripts'])]
    if mode in ['browser', 'compat', 'all']:
        steps += [('web-assets', ['npm', '--prefix', 'terminal', 'run', 'sync']),
                  ('browser-security', ['node', 'tests/browser/security.cjs'])]
    if mode in ['build', 'all']:
        steps += [('dual-abi-build', ['./scripts/build-debug.sh'])]
    if mode in ['device', 'all']:
        steps += [('native-flow', ['./scripts/test-native-flow.sh']), ('native-auth', ['./scripts/test-native-auth.sh']),
                  ('native-security', ['./scripts/test-native-security.sh']),
                  ('device-storage', [sys.executable, 'scripts/verify-device-storage.py'])]
        for scenario in ['smoke', 'auth-negative', 'credentials', 'keyboard-tools', 'reconnect']:
            steps += [('ui-' + scenario, ['env', 'HT_UI_SCENARIO=' + scenario, './scripts/test-ui.sh'])]
    if mode in ['compat', 'all']:
        steps += [('openssh-compat', ['./scripts/test-openssh.sh'])]
    if mode in ['soak', 'all']:
        steps += [('soak', ['env', 'HT_UI_SCENARIO=soak', './scripts/test-ui.sh'])]
    if mode in ['build', 'device', 'all']:
        steps += [('artifact-audit', [sys.executable, 'scripts/audit-hap.py', 'entry/build/default/outputs/default/entry-default-unsigned.hap'])]
    return steps


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['unit', 'browser', 'build', 'device', 'compat', 'soak', 'all'])
    args = parser.parse_args()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    directory = ROOT / '.runtime/verification' / (stamp + '-' + args.mode)
    steps = plan(args.mode)
    reporter = Reporter(directory, args.mode, steps)
    passed = True
    try:
        for i, (_, command) in enumerate(steps):
            if not reporter.run(i, command):
                passed = False
                if args.mode in ['device', 'soak', 'all']:
                    capture_failure(directory, Path(os.environ.get('DEVECO_HOME', '/Applications/DevEco-Studio.app/Contents')),
                                    datetime.datetime.fromisoformat(reporter.report['startedAt']).timestamp())
                break
    except BaseException:
        reporter.finish(False)
        raise
    passed = reporter.finish(passed)
    print('Report: ' + str(directory / 'report.md'))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
