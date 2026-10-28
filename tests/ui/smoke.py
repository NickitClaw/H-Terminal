"""Run against the installed production HAP and an isolated local SSH fixture."""
import base64
import json
import os
import re
import subprocess
import time
import uuid
from pathlib import Path

HDC = os.environ['HT_HDC']
WORK = Path(os.environ['HT_UI_WORK'])
PORT = os.environ['HT_UI_PORT']
AUTH_PORT = os.environ.get('HT_AUTH_PORT', '22228')


def call(*args):
    subprocess.run([HDC, *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20)


def layout():
    for attempt in range(2):
        try:
            call('shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/hterminal-ui-layout.json')
            break
        except subprocess.TimeoutExpired:
            if attempt:
                raise
    call('file', 'recv', '/data/local/tmp/hterminal-ui-layout.json', str(WORK / 'layout.json'))
    result = []
    def walk(value):
        if isinstance(value, dict):
            if 'attributes' in value:
                result.append(value['attributes'])
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(json.loads((WORK / 'layout.json').read_text()))
    return result


def find(entries, text, kind=None):
    return next((a for a in reversed(entries) if a.get('text') == text and
                 (kind is None or a.get('type') == kind)), None)


def by_id(entries, identifier):
    return next((a for a in entries if a.get('key') == identifier or a.get('id') == identifier), None)


def dialog(entries, title):
    return next((a for a in entries if a.get('type') == 'AlertDialog' and title in a.get('text', '')), None)


def credential_delete(entries, name):
    current = ''
    for item in entries:
        if item.get('type') == 'Text' and item.get('text', '').startswith('Credential-HT-ui-'):
            current = item['text']
        if current == name and (item.get('key') or item.get('id') or '').startswith('credential-delete-'):
            return item
    raise AssertionError('credential row missing: ' + name)


def press(text, key_id, expected):
    entries = wait(lambda e: by_id(e, 'key-' + key_id) and by_id(e, 'key-' + key_id).get('enabled') == 'true')
    previous = sum(line.startswith('INPUT ') for line in (WORK / 'server.log').read_text().splitlines())
    click(find(entries, text, 'Text'))
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        frames = [line for line in (WORK / 'server.log').read_text().splitlines() if line.startswith('INPUT ')]
        if len(frames) > previous:
            assert base64.b64decode(frames[-1].split(' ', 2)[2]) == expected, frames
            return
        time.sleep(.05)
    raise AssertionError('remote fixture did not receive the enabled key')


def wait(predicate):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        entries = layout()
        if predicate(entries):
            return entries
        time.sleep(.2)
    raise AssertionError('UI state timeout; inspect the local fixture, device lock and IME setup')


def click(item):
    assert item is not None
    identifier = item.get('key') or item.get('id')
    if identifier in ['host-address', 'host-port', 'host-username', 'auth-secret', 'profile-name',
                      'auth-method', 'save-host', 'trust-record', 'connect-submit', 'connect-close',
                      'credential-import', 'credential-select']:
        item = visible(identifier)
    left, top, right, bottom = map(int, re.findall(r'-?\d+', item['bounds']))
    call('shell', 'uitest', 'uiInput', 'click', str((left + right) // 2), str((top + bottom) // 2))


def fill(index, value):
    identifier = ['host-address', 'host-port', 'host-username', 'auth-secret', 'profile-name'][index]
    field = visible(identifier)
    click(field)
    call('shell', 'uitest', 'uiInput', 'keyEvent', '2072', '2017')  # Ctrl+A
    if value:
        call('shell', 'uitest', 'uiInput', 'text', value)
    else:
        call('shell', 'uitest', 'uiInput', 'keyEvent', '2055')


def visible(identifier):
    for _ in range(12):
        entries = layout()
        field = by_id(entries, identifier)
        container = by_id(entries, 'connect-form')
        if container is None:
            assert field is not None, identifier
            return field
        left, top, right, bottom = map(int, re.findall(r'-?\d+', container['bounds']))
        ftop, fbottom = top - 1, bottom + 1
        if field:
            _, ftop, _, fbottom = map(int, re.findall(r'-?\d+', field['bounds']))
        if field and ftop >= top and fbottom <= bottom:
            return field
        x = left + 12
        y1, y2 = top + 30, bottom - 30
        above = ftop < top if field else identifier in ['host-address', 'host-port', 'host-username', 'auth-secret', 'auth-method']
        if above:
            call('shell', 'uitest', 'uiInput', 'swipe', str(x), str(y1), str(x), str(y2), '1000')
        else:
            call('shell', 'uitest', 'uiInput', 'swipe', str(x), str(y2), str(x), str(y1), '1000')
    raise AssertionError('could not scroll to ' + identifier)


def select_auth(method):
    click(by_id(layout(), 'auth-method'))
    entries = wait(lambda e: find(e, method, 'Text'))
    click(find(entries, method, 'Text'))


def finish_authentication():
    for _ in range(3):
        entries = wait(lambda e: find(e, 'OPEN') or by_id(e, 'auth-answer-0') or find(e, 'FAILED') or find(e, 'CLOSED'))
        if find(entries, 'OPEN'):
            return
        assert not find(entries, 'FAILED') and not find(entries, 'CLOSED'), 'authentication ended early'
        answers = ['review', '123456'] if find(entries, 'User code') else ['654321']
        print('UI authentication round, fields=' + str(len(answers)), flush=True)
        for index, value in enumerate(answers):
            click(by_id(layout(), 'auth-answer-' + str(index)))
            call('shell', 'uitest', 'uiInput', 'text', value)
        time.sleep(.2)
        click(by_id(layout(), 'auth-submit'))
    wait(lambda e: find(e, 'OPEN'))


def connect(port=PORT, method='密码', complete=True, automatic=False, username='review'):
    entries = layout()
    if not by_id(entries, 'connect-form'):
        click(find(entries, '连接', 'Button'))
    wait(lambda e: by_id(e, 'connect-form'))
    for index, value in enumerate(['10.0.2.2', port, username]):
        fill(index, value)
    select_auth(method)
    fill(3, 'review' if method == '密码' else '')
    call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
    toggle = visible('auto-reconnect')
    if (toggle.get('checked') == 'true') != automatic:
        click(toggle)
    click(find(layout(), '连接', 'Button'))
    entries = wait(lambda e: find(e, '重置终端并连接') or find(e, '验证主机密钥') or find(e, 'OPEN') or find(e, 'FAILED') or by_id(e, 'auth-answer-0'))
    if find(entries, '重置终端并连接'):
        click(find(entries, '重置终端并连接'))
        entries = wait(lambda e: find(e, '验证主机密钥') or find(e, 'OPEN') or find(e, 'FAILED') or by_id(e, 'auth-answer-0'))
    if find(entries, 'FAILED'):
        assert any('host key does not match' in a.get('text', '') for a in entries), entries
        # An earlier disposable fixture may have used this local endpoint.
        # Exercise the explicit trust reset flow; never silently accept a changed key.
        click(find(entries, '信任记录', 'Button'))
        entries = wait(lambda e: find(e, '已信任的主机指纹'))
        click(find(entries, '清除此指纹'))
        wait(lambda e: not find(e, '已信任的主机指纹') and find(e, '信任记录', 'Button'))
        fill(3, 'review' if method == '密码' else '')
        call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
        click(find(layout(), '连接', 'Button'))
        entries = layout()
        if find(entries, '重置终端并连接'):
            click(find(entries, '重置终端并连接'))
        entries = wait(lambda e: find(e, '验证主机密钥') or find(e, 'OPEN') or by_id(e, 'auth-answer-0'))
    if find(entries, '验证主机密钥'):
        # Trust applies exclusively to this generated local fixture key.
        click(find(entries, '信任并继续'))
    if not complete:
        return
    if method != '密码':
        finish_authentication()
    wait(lambda e: find(e, 'OPEN') and find(e, '断开', 'Button'))


def credentials_flow():
    manifest = json.loads((WORK / 'picker-files.json').read_text())
    # A failed prior run can leave its synthetic vault entries behind. Remove
    # only this fixture namespace through the normal confirmation flow.
    click(find(layout(), '凭据', 'Button'))
    entries = wait(lambda e: find(e, '受保护的导入凭据'))
    for _ in range(30):
        previous = next((a['text'] for a in entries if a.get('type') == 'Text' and
            re.fullmatch(r'Credential-HT-ui-[0-9a-f]{8}-(plain|encrypted|invalid)\.pem', a.get('text', ''))), None)
        if previous is None:
            break
        delete = credential_delete(entries, previous)
        identifier = delete.get('key') or delete.get('id')
        click(delete)
        entries = wait(lambda e: dialog(e, '删除凭据'))
        click(find(entries, '删除凭据', 'Text'))
        entries = wait(lambda e: not by_id(e, identifier))
    else:
        raise AssertionError('too many stale synthetic credentials')
    click(find(entries, '返回', 'Button'))
    for index in [0, 1, 2]:
        entries = layout()
        if not by_id(entries, 'connect-form'):
            click(find(entries, '连接', 'Button'))
        for field, value in enumerate(['10.0.2.2', AUTH_PORT, 'review']):
            fill(field, value)
        select_auth('Ed25519 私钥')
        name = 'Credential-' + manifest['names'][index]
        fill(4, name)
        fill(3, 'key-passphrase' if index == 1 else '')
        call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
        click(by_id(layout(), 'credential-import'))
        filename = manifest['names'][index]
        browsed = storage = searched = False
        for _ in range(20):
            entries = layout()
            item = find(entries, filename, 'Text') or find(entries, filename.removesuffix('.pem'), 'Text')
            if item:
                click(item)
                entries = wait(lambda e: find(e, '完成') or (not by_id(e, '__SearchField__top_search') and
                    by_id(e, 'credential-import') and by_id(e, 'credential-import').get('enabled') == 'true'))
                if find(entries, '完成'):
                    click(find(entries, '完成'))
                break
            if find(entries, '知道了', 'Text'):
                click(find(entries, '知道了', 'Text'))
            elif not browsed and find(entries, '浏览', 'Text'):
                click(find(entries, '浏览', 'Text')); browsed = True
            elif not storage and find(entries, '我的手机', 'Text'):
                click(find(entries, '我的手机', 'Text')); storage = True
            elif storage and not searched and by_id(entries, '__SearchField__top_search'):
                click(by_id(entries, '__SearchField__top_search'))
                call('shell', 'uitest', 'uiInput', 'text', filename)
                call('shell', 'uitest', 'uiInput', 'keyEvent', '2054')
                searched = True
            time.sleep(.2)
        else:
            raise AssertionError('fixture file was not visible in the system document picker')
        visible('credential-import')
        entries = wait(lambda e: by_id(e, 'credential-import') and by_id(e, 'credential-import').get('enabled') == 'true')
        if index == 2:
            click(find(entries, '凭据', 'Button'))
            entries = wait(lambda e: find(e, '受保护的导入凭据'))
            assert not find(entries, name, 'Text'), 'invalid private key was saved'
            click(find(entries, '返回', 'Button'))
            print('PASS: system picker invalid key rejected', flush=True)
            continue
        # A file passphrase is intentionally not retained after import.
        fill(3, 'key-passphrase' if index == 1 else '')
        call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
        click(visible('connect-submit'))
        entries = wait(lambda e: find(e, '重置终端并连接') or find(e, '验证主机密钥') or find(e, 'OPEN') or find(e, 'FAILED'))
        if find(entries, '重置终端并连接'):
            click(find(entries, '重置终端并连接'))
            entries = wait(lambda e: find(e, '验证主机密钥') or find(e, 'OPEN') or find(e, 'FAILED'))
        if find(entries, '验证主机密钥'):
            click(find(entries, '信任并继续'))
        elif find(entries, 'FAILED'):
            # Reuse the explicit fixture-only trust reset flow.
            connect(AUTH_PORT, 'Ed25519 私钥')
        wait(lambda e: find(e, 'OPEN'))
        click(find(layout(), '凭据', 'Button'))
        entries = wait(lambda e: find(e, name))
        delete = credential_delete(entries, name)
        identifier = delete.get('key') or delete.get('id')
        click(delete)
        assert not dialog(layout(), '删除凭据'), 'active key deletion was offered'
        click(find(layout(), '返回', 'Button'))
        click(find(layout(), '断开', 'Button'))
        wait(lambda e: find(e, 'CLOSED'))
        click(find(layout(), '凭据', 'Button'))
        click(by_id(wait(lambda e: by_id(e, identifier)), identifier))
        entries = wait(lambda e: dialog(e, '删除凭据'))
        click(find(entries, '删除凭据', 'Text'))
        wait(lambda e: not by_id(e, identifier))
        click(find(layout(), '返回', 'Button'))
        print('PASS: system picker import, HUKS and actual ' + ('encrypted' if index == 1 else 'plain') +
              ' Ed25519 login, active deletion guard and cleanup', flush=True)


def main():
    wait(lambda e: find(e, '连接 SSH 服务器'))
    if os.environ.get('HT_UI_SCENARIO') == 'soak':
        from soak import run
        run()
        return
    if os.environ.get('HT_UI_SCENARIO') == 'credentials':
        credentials_flow()
        return
    if os.environ.get('HT_UI_SCENARIO') == 'reconnect':
        connect(automatic=True)
        entries = wait(lambda e: find(e, 'H-Terminal 重新认证') and by_id(e, 'auth-answer-0'))
        assert find(entries, '本次连接密码'), 'automatic reconnect did not ask for a fresh secret'
        click(by_id(entries, 'auth-answer-0'))
        call('shell', 'uitest', 'uiInput', 'text', 'review')
        call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
        click(by_id(layout(), 'auth-submit'))
        wait(lambda e: find(e, 'OPEN'))
        press('Q', 'q', b'q')
        opens = [line for line in (WORK / 'server.log').read_text().splitlines() if line.startswith('OPEN ')]
        assert len(opens) == 2 and opens[0] != opens[1]
        click(by_id(layout(), 'key-ctrl'))
        press('D', 'd', b'\x04')
        entries = wait(lambda e: by_id(e, 'stop-reconnect'))
        click(by_id(entries, 'stop-reconnect'))
        wait(lambda e: not by_id(e, 'stop-reconnect'))
        time.sleep(2)
        assert len([line for line in (WORK / 'server.log').read_text().splitlines() if line.startswith('OPEN ')]) == 2
        print('PASS: actual network loss, fresh authentication, new SSH connection, no replay and user cancellation', flush=True)
        return
    if os.environ.get('HT_UI_SCENARIO') == 'keyboard-tools':
        connect()
        press('Q', 'q', b'q')
        entries = layout()
        key = by_id(entries, 'key-ArrowLeft')
        left, top, right, bottom = map(int, re.findall(r'-?\d+', key['bounds']))
        call('shell', 'uitest', 'uiInput', 'longClick', str((left + right) // 2), str((top + bottom) // 2))
        time.sleep(.3)
        frames = [line for line in (WORK / 'server.log').read_text().splitlines() if line.startswith('INPUT ')]
        arrows = [base64.b64decode(line.split(' ', 2)[2]) for line in frames[1:]]
        assert len(arrows) >= 2 and all(value == b'\x1b[D' for value in arrows), arrows
        time.sleep(.3)
        assert len(frames) == sum(line.startswith('INPUT ') for line in (WORK / 'server.log').read_text().splitlines()), 'repeat survived release'
        press('Q', 'q', b'q')
        # Inject platform keyboard events into the actual ArkWeb textarea.
        click(by_id(layout(), 'terminal-session-1'))
        for codes, expected_bytes in [(['2017'], b'a'), (['2072', '2019'], b'\x03')]:
            previous = sum(line.startswith('INPUT ') for line in (WORK / 'server.log').read_text().splitlines())
            call('shell', 'uitest', 'uiInput', 'keyEvent', *codes)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                input_frames = [line for line in (WORK / 'server.log').read_text().splitlines() if line.startswith('INPUT ')]
                if len(input_frames) > previous:
                    assert base64.b64decode(input_frames[-1].split(' ', 2)[2]) == expected_bytes, input_frames[-1]
                    time.sleep(.15)
                    assert sum(line.startswith('INPUT ') for line in (WORK / 'server.log').read_text().splitlines()) == previous + 1
                    break
                time.sleep(.05)
            else:
                raise AssertionError('platform keyboard event did not reach SSH exactly once')
        click(by_id(layout(), 'terminal-tools'))
        entries = wait(lambda e: by_id(e, 'font-value'))
        old = int(find(entries, next(a['text'] for a in entries if a.get('id') == 'font-value'))['text'].split()[-1])
        click(by_id(entries, 'font-larger' if old < 28 else 'font-smaller'))
        expected = old + (1 if old < 28 else -1)
        wait(lambda e: find(e, '字号 ' + str(expected)))
        click(by_id(layout(), 'terminal-search'))
        call('shell', 'uitest', 'uiInput', 'text', 'fixture')
        call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
        click(by_id(layout(), 'search-next'))
        count = sum(line.startswith('INPUT ') for line in (WORK / 'server.log').read_text().splitlines())
        click(by_id(layout(), 'local-selection'))
        wait(lambda e: by_id(e, 'key-q') and by_id(e, 'key-q').get('enabled') == 'false')
        click(by_id(layout(), 'terminal-tools'))
        wait(lambda e: find(e, '返回实时终端'))
        assert sum(line.startswith('INPUT ') for line in (WORK / 'server.log').read_text().splitlines()) == count
        click(by_id(layout(), 'local-selection'))
        press('Q', 'q', b'q')
        call('shell', 'aa', 'force-stop', 'com.nickitclaw.hterminal')
        call('shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.nickitclaw.hterminal')
        wait(lambda e: by_id(e, 'terminal-tools'))
        click(by_id(layout(), 'terminal-tools'))
        wait(lambda e: find(e, '字号 ' + str(expected)))
        print('PASS: actual touch repeat/release, font changes and persistence, local search and read-only selection', flush=True)
        return
    if os.environ.get('HT_UI_SCENARIO') == 'auth-negative':
        for action in ['wrong', 'cancel', 'background', 'timeout']:
            connect(AUTH_PORT, '交互式认证', complete=False)
            wait(lambda e: by_id(e, 'auth-answer-0'))
            if action == 'wrong':
                click(by_id(layout(), 'auth-answer-0'))
                call('shell', 'uitest', 'uiInput', 'text', 'wrong')
                call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
                click(by_id(layout(), 'auth-submit'))
                wait(lambda e: find(e, 'FAILED') and not by_id(e, 'auth-answer-0'))
            elif action == 'cancel':
                click(find(layout(), '取消认证', 'Button'))
                wait(lambda e: find(e, 'CLOSED') and not by_id(e, 'auth-answer-0'))
            elif action == 'background':
                call('shell', 'uitest', 'uiInput', 'keyEvent', 'Home')
                time.sleep(.3)
                call('shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.nickitclaw.hterminal')
                wait(lambda e: find(e, 'CLOSED') and not by_id(e, 'auth-answer-0'))
            else:
                # Exercise the production 120-second native prompt deadline.
                for elapsed in range(0, 125, 5):
                    if find(layout(), 'FAILED'):
                        break
                    if elapsed % 30 == 0:
                        print('UI waiting for authentication timeout, seconds=' + str(elapsed), flush=True)
                    time.sleep(5)
                wait(lambda e: find(e, 'FAILED') and not by_id(e, 'auth-answer-0'))
            print('PASS: actual MFA ' + action + ', no lingering answer form', flush=True)
        return
    if os.environ.get('HT_UI_SCENARIO') == 'auth':
        connect(AUTH_PORT, '交互式认证')
        print('PASS: UI authentication', flush=True)
        return
    connect()
    press('Q', 'q', b'q')
    click(find(layout(), '断开', 'Button'))
    wait(lambda e: find(e, 'CLOSED'))
    connect()
    press('W', 'w', b'w')
    click(by_id(layout(), 'new-session'))
    wait(lambda e: by_id(e, 'tab-session-2'))
    connect()
    press('X', 'x', b'x')
    wait(lambda e: sum(a.get('type') == 'Text' and a.get('text', '').endswith('· OPEN') for a in e) >= 2)
    click(by_id(layout(), 'tab-session-1'))
    press('E', 'e', b'e')
    call('shell', 'uitest', 'uiInput', 'keyEvent', 'Home')
    time.sleep(.2)
    call('shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.nickitclaw.hterminal')
    press('R', 'r', b'r')
    records = (WORK / 'server.log').read_text().splitlines()
    frames = [line.split(' ', 2) for line in records if line.startswith('INPUT ')]
    assert [base64.b64decode(frame[2]) for frame in frames] == [b'q', b'w', b'x', b'e', b'r'], frames
    assert frames[0][1] != frames[1][1], frames
    assert frames[1][1] == frames[3][1] == frames[4][1] and frames[2][1] != frames[1][1], frames
    print('PASS: real UI reconnect, two live tabs, isolated keys, retained connection and foreground server check', flush=True)

    click(by_id(layout(), 'new-session'))
    connect(AUTH_PORT, '交互式认证')
    click(find(layout(), '断开', 'Button'))
    wait(lambda e: find(e, 'CLOSED'))
    print('PASS: actual two-round MFA form, echo and secret answers', flush=True)

    entries = layout()
    if find(entries, '完整', 'Button'):
        click(find(entries, '完整', 'Button'))
    wait(lambda e: find(e, '紧凑', 'Button'))
    entries = layout()
    if find(entries, '手动上下布局'):
        click(find(entries, '布局', 'Button'))
        entries = wait(lambda e: find(e, '普通布局'))
    before = by_id(entries, 'terminal-session-3')['bounds']
    for _ in range(3):
        entries = layout()
        if find(entries, '手动上下布局'):
            break
        click(find(entries, '布局', 'Button'))
    wait(lambda e: find(e, '手动上下布局'))
    after = by_id(layout(), 'terminal-session-3')['bounds']
    assert before != after, ('manual layout did not resize the active terminal', before, after)

    name = 'UI-fixture-' + uuid.uuid4().hex[:8]
    fill(4, name)
    call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
    click(by_id(layout(), 'save-host'))
    click(find(layout(), '主机', 'Button'))
    entries = wait(lambda e: find(e, f'{name} · 10.0.2.2:{AUTH_PORT}', 'Button'))
    row = find(entries, f'{name} · 10.0.2.2:{AUTH_PORT}', 'Button')
    identifier = row.get('key') or row.get('id')
    click(row)
    fill(4, name + '-edited')
    call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
    click(by_id(layout(), 'save-host'))
    # Restart exercises the real platform Preferences store, not its test adapter.
    time.sleep(.2)
    call('shell', 'aa', 'force-stop', 'com.nickitclaw.hterminal')
    call('shell', 'aa', 'start', '-a', 'EntryAbility', '-b', 'com.nickitclaw.hterminal')
    entries = wait(lambda e: find(e, '主机', 'Button') and find(e, '主机', 'Button').get('enabled') == 'true')
    assert find(entries, '紧凑', 'Button') and find(entries, '手动上下布局'), 'keyboard/layout preferences did not persist'
    click(find(entries, '主机', 'Button'))
    entries = wait(lambda e: find(e, f'{name}-edited · 10.0.2.2:{AUTH_PORT}', 'Button'))
    assert not find(entries, f'{name} · 10.0.2.2:{AUTH_PORT}', 'Button')
    profile_id = identifier.removeprefix('host-')
    click(by_id(entries, 'delete-' + profile_id))
    entries = wait(lambda e: find(e, '删除主机配置'))
    click(find(entries, '删除', 'Text'))
    wait(lambda e: not find(e, f'{name}-edited · 10.0.2.2:{AUTH_PORT}', 'Button'))
    print('PASS: platform host create, edit, application restart, persisted layout/keyboard preferences and delete', flush=True)


if __name__ == '__main__':
    main()
