#!/usr/bin/env python3
"""Audit the normal distributable; never inspect user or signing-key storage."""
import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path


def audit(path):
    required = {f'libs/{abi}/{name}' for abi in ['arm64-v8a', 'x86_64']
                for name in ['libentry.so', 'libssh.so.4', 'libcrypto.so.3']}
    with zipfile.ZipFile(path) as package:
        names = set(package.namelist())
        assert required <= names, 'required dual-ABI libraries are missing'
        for name in names:
            assert not any(part in name.split('/') for part in ['node_modules', 'tests', '.runtime']), 'development data in HAP: ' + name
            content = package.read(name)
            if name.endswith(('.abc', '.map', '.js', '.json', '.html')):
                assert b'HT_PROBE_' not in content and b'verifyDeviceStorage' not in content, 'device probe in HAP: ' + name
            assert not re.search(rb'-----BEGIN (?:OPENSSH |RSA |EC |ENCRYPTED )?PRIVATE KEY-----\s*\n[A-Za-z0-9+/=\r\n]{60,}-----END', content), 'embedded private key in HAP: ' + name
    return {'artifact': str(path), 'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            'dualAbiLibraries': sorted(required), 'probeFree': True, 'embeddedPrivateKeys': False}


if __name__ == '__main__':
    print(json.dumps(audit(Path(sys.argv[1])), indent=2))
