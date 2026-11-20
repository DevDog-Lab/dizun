#!/usr/bin/env python3
"""Conservative, dependency-free repository guard. NOT a substitute for gitleaks/manual review."""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_SCAN = 5 * 1024 * 1024
# Brand assets the user provided and a human reviewed before commit (the app
# icon, 2026-11-19; inspected visually and dimension-checked — image data
# only). This is a narrow allowlist, NOT a general binary exemption.
APPROVED_BINARY_ASSET = re.compile(r'(^|/)Assets/[^/]+\.(?:png|icns|svg)$', re.I)
NAME_BLOCK = re.compile(r'(^|/)(\.env(?:\..*)?|id_rsa(?:\..*)?|id_ed25519(?:\..*)?|[^/]*\.(?:pem|key|p8|p12|pfx|kdbx|mobileprovision)|credentials\.json|service-account[^/]*\.json)$', re.I)
PATTERNS = [
    ('private key', re.compile(rb'-----BEGIN (?:OPENSSH |RSA |EC |DSA |ENCRYPTED )?PRIVATE KEY-----')),
    ('github token', re.compile(rb'gh(?:p|o|u|s|r)_[A-Za-z0-9_]{20,}')),
    ('github fine-grained token', re.compile(rb'github_pat_[A-Za-z0-9_]{20,}')),
    ('aws access key', re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b')),
    ('slack token', re.compile(rb'\bxox[baprs]-[A-Za-z0-9-]{10,}')),
    ('generic credential assignment', re.compile(rb'(?im)^\s*(?:export\s+)?(?:API[_-]?KEY|ACCESS[_-]?TOKEN|SECRET[_-]?KEY|CLIENT[_-]?SECRET|PASSWORD|AUTH[_-]?TOKEN)\s*[:=]\s*["\']?(?!<|YOUR_|PLACEHOLDER|EXAMPLE|REDACTED|dummy|test|fake)[^\s"\']{12,}')),
]

def git(*args, input_data=None):
    return subprocess.run(['git', *args], cwd=ROOT, input=input_data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout

def staged():
    paths = [p.decode('utf-8', 'replace') for p in git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').split(b'\0') if p]
    return [(path, git('show', ':' + path)) for path in paths]

def history():
    # Scan all reachable commit objects, not merely working tree. Includes file contents and commit messages.
    objects = [o for o in git('rev-list', '--objects', '--all').decode('utf-8','replace').splitlines() if o]
    scanned = []
    for entry in objects:
        sha, _, path = entry.partition(' ')
        if not path:
            continue
        kind = git('cat-file', '-t', sha).strip()
        if kind != b'blob':
            continue
        if NAME_BLOCK.search(path):
            scanned.append((path + ' [history]', b'', True))
        size = int(git('cat-file', '-s', sha))
        if size > MAX_SCAN:
            scanned.append((path + ' [history oversized]', b'', True))
            continue
        scanned.append((path + ' [history]', git('cat-file', 'blob', sha), False))
    for sha in git('rev-list', '--all').decode().splitlines():
        message = git('log', '-1', '--format=%B', sha)
        scanned.append((f'commit message {sha[:12]}', message, False))
    return scanned

def check(items):
    issues = []
    count = 0
    for item in items:
        path, data, flagged = (item if len(item) == 3 else (*item, False))
        count += 1
        if NAME_BLOCK.search(path.split(' [history]')[0]):
            issues.append((path, 'blocked sensitive filename'))
        if flagged:
            issues.append((path, 'unscanned / oversized historical object or forbidden path'))
        if len(data) > MAX_SCAN:
            issues.append((path, 'file exceeds safe scanner size; manual review required'))
            continue
        if b'\x00' in data[:4096]:
            if not APPROVED_BINARY_ASSET.search(path.split(' [history]')[0]):
                # Binary files could hide secrets; block until an explicit review instead of falsely reporting clean.
                issues.append((path, 'binary content requires explicit review / removal'))
                continue
        for title, pattern in PATTERNS:
            if pattern.search(data):
                issues.append((path, title))
    for path, issue in sorted(set(issues)):
        print(f'BLOCKED: {path}: {issue}', file=sys.stderr)
    print(f'Guard checked {count} items; findings: {len(set(issues))}. This is not a complete secrets audit.')
    return 1 if issues else 0

if __name__ == '__main__':
    if len(sys.argv) != 2 or sys.argv[1] not in ('staged', 'history'):
        print('Usage: repo_guard.py staged|history', file=sys.stderr)
        sys.exit(2)
    try:
        sys.exit(check(staged() if sys.argv[1] == 'staged' else history()))
    except subprocess.CalledProcessError as exc:
        print('BLOCKED: repository scan failed (run from a Git checkout).', file=sys.stderr)
        sys.exit(2)
