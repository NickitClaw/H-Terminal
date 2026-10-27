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
    call('shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/hterminal-ui-layout.json')
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
                      'auth-method', 'save-host', 'trust-record', 'connect-submit', 'connect-close']:
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
        assert field is not None, identifier
        if container is None:
            return field
        left, top, right, bottom = map(int, re.findall(r'-?\d+', container['bounds']))
        _, ftop, _, fbottom = map(int, re.findall(r'-?\d+', field['bounds']))
        if ftop >= top and fbottom <= bottom:
            return field
        x = left + 12
        y1, y2 = top + 30, bottom - 30
        if ftop < top:
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


def connect(port=PORT, method='密码'):
    entries = layout()
    if not find(entries, '连接 SSH 服务器'):
        click(find(entries, '连接', 'Button'))
    wait(lambda e: find(e, '连接 SSH 服务器'))
    for index, value in enumerate(['10.0.2.2', port, 'review']):
        fill(index, value)
    select_auth(method)
    fill(3, 'review' if method == '密码' else '')
    call('shell', 'uitest', 'uiInput', 'keyEvent', 'Back')
    click(find(layout(), '连接', 'Button'))
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
        entries = wait(lambda e: find(e, '验证主机密钥') or find(e, 'OPEN') or by_id(e, 'auth-answer-0'))
    if find(entries, '验证主机密钥'):
        # Trust applies exclusively to this generated local fixture key.
        click(find(entries, '信任并继续'))
    if method != '密码':
        finish_authentication()
    wait(lambda e: find(e, 'OPEN') and find(e, '断开', 'Button'))


def main():
    wait(lambda e: find(e, '连接 SSH 服务器'))
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
