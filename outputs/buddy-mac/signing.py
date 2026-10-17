"""Keep Buddy's code-signing identity stable across local app updates."""
from pathlib import Path
import json
import os
import re
import subprocess

SETTINGS = Path.home() / 'Library/Application Support/Buddy/Signing/identity.json'


def identity():
    result = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    available = dict(re.findall(r'\) ([A-F0-9]{40}) "([^"]+)"', result))
    requested = os.environ.get('BUDDY_SIGNING_IDENTITY')
    if not requested and SETTINGS.exists():
        requested = json.loads(SETTINGS.read_text())['sha1']
    if not requested:
        candidates = [key for key, name in available.items() if name.startswith('Developer ID Application:')]
        if len(candidates) != 1:
            raise RuntimeError('Choose a persistent signing certificate with BUDDY_SIGNING_IDENTITY. Buddy must not fall back to ad-hoc signing, which resets macOS permissions on updates.')
        requested = candidates[0]
    requested = requested.upper()
    if not re.fullmatch(r'[A-F0-9]{40}', requested) or requested not in available:
        raise RuntimeError('Buddy’s saved signing identity is unavailable or expired. Restore that identity or explicitly choose its replacement; ad-hoc fallback is disabled.')
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps({'sha1': requested, 'name': available[requested]}, indent=2) + '\n')
    return requested


def requirement(bundle):
    result = subprocess.run(['codesign', '-d', '-r-', str(bundle)], capture_output=True, text=True, check=True)
    match = re.search(r'(?:# )?designated => (.+)', result.stdout + result.stderr)
    if not match:
        raise RuntimeError('Buddy has no verifiable designated requirement.')
    return match.group(1)


def verify_update(previous, replacement):
    old, new = requirement(previous), requirement(replacement)
    if 'cdhash ' in new:
        raise RuntimeError('Refusing an ad-hoc update that would invalidate macOS privacy approvals.')
    # Existing development builds need one migration from a content hash to a
    # real signing certificate. Later updates must satisfy the existing rule.
    if 'cdhash ' not in old:
        subprocess.run(['codesign', '--verify', '--strict', '-R', '=' + old, str(replacement)], check=True)
