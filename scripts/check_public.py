#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Conservative release-file checks; not a guarantee that all secrets are detected."""
import ipaddress
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
NETWORKS = [ipaddress.ip_network(value) for value in (
    '0.0.0.0/32', '127.0.0.0/8', '192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24',
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
ALLOWED_HOSTS = {
    'github.com', 'raw.githubusercontent.com', 'wiki.metacubex.one', 'openwrt.org',
    'www.msftconnecttest.com', 'www.baidu.com', 'www.gstatic.com', 'fsf.org', 'www.gnu.org',
    'gnu.org', 'check.example.org', 'node.example.org', 'endpoint.example.org',
}
BLOCKED_SUFFIXES = {'.pcap', '.pcapng', '.pem', '.key', '.sqlite', '.db', '.ipk', '.gz', '.log'}
failures = []
try:
    tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z'], stderr=subprocess.DEVNULL).decode().split('\0')
except subprocess.CalledProcessError:
    tracked = []
files = [ROOT / value for value in tracked if value] or [p for p in ROOT.rglob('*') if p.is_file() and '.git' not in p.relative_to(ROOT).parts]
for path in files:
    name = path.relative_to(ROOT).as_posix()
    if path.is_symlink() or any(part in {'private', 'generated', 'runtime', '__pycache__'} for part in path.relative_to(ROOT).parts) or path.suffix in BLOCKED_SUFFIXES:
        failures.append((name, 'private/generated/binary path'))
        continue
    if path.stat().st_size > 256 * 1024:
        failures.append((name, 'unexpected large file'))
        continue
    try:
        text = path.read_text(encoding='utf-8')
    except UnicodeError:
        failures.append((name, 'non-UTF-8 data'))
        continue
    if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]{20,}', text):
        failures.append((name, 'credential signature'))
    if re.search(r'[A-Z]:\\(?:Users|0资源库)\\|/Users/[\w.-]+/', text):
        failures.append((name, 'personal absolute path'))
    for match in re.finditer(r'\b(?:\d{1,3}\.){3}\d{1,3}\b', text):
        try:
            address = ipaddress.ip_address(match.group())
        except ValueError:
            continue
        if not any(address in network for network in NETWORKS):
            failures.append((name, 'non-example public IPv4'))
    for match in re.finditer(r'https?://[^\s<>"\x27)]+', text):
        parsed = urllib.parse.urlsplit(match.group().rstrip('.,'))
        host = parsed.hostname or ''
        try:
            address = ipaddress.ip_address(host)
            allowed = any(address in network for network in NETWORKS)
        except ValueError:
            allowed = host in ALLOWED_HOSTS or host.endswith(('.example.org', '.example.edu'))
        if not allowed:
            failures.append((name, 'unexpected URL host'))
        if parsed.password:
            failures.append((name, 'URL credentials'))
    for line in text.splitlines():
        assignment = re.search(r'(?:password|proxy-user|api_key|token|secret)\s*["\x27]?\s*[:=]\s*["\x27]([^"\x27]+)', line, re.IGNORECASE)
        if assignment and not assignment.group(1).startswith(('REPLACE_', 'TEST_ONLY', 'test_', '#{', '/etc/')):
            # Code expressions, regexes and field-name tables are not literal credentials.
            if not any(fragment in line for fragment in ('fetch(', 'File.', 'ENV[', '=>', 'r\x27', 'r"', 're.search', 'regex')):
                failures.append((name, 'review literal credential assignment'))

if failures:
    for name, reason in sorted(set(failures)):
        print(f'FAIL {name}: {reason}')
    sys.exit(1)
print(f'PASS: {len(files)} release files; no flagged credentials, private paths or unexpected public endpoints')
