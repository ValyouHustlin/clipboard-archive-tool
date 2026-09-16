#!/usr/bin/env python3
"""Launch the app in a private scratch tree, with filesystem containment.
Usage: run-isolated-app.py /tmp/unique-directory /absolute/path/to/executable
The named pasteboard follows the support-root digest; clock is support/clock.txt.
"""
import json
import os
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit(__doc__)
root = Path(sys.argv[1]).resolve()
if not str(root).startswith('/private/tmp/') and not str(root).startswith('/tmp/'):
    raise SystemExit('scratch root must be a directory beneath /tmp')
executable = Path(sys.argv[2]).resolve(strict=True)
root.mkdir(mode=0o700, parents=True, exist_ok=True)
for child in ['support', 'archive', 'index', 'home', 'tmp']:
    path = root / child
    path.mkdir(mode=0o700, exist_ok=True)
    if not path.resolve().is_relative_to(root):
        raise SystemExit('scratch directory resolves outside the scratch root')
env = os.environ.copy()
env.update(CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT=str(root/'support'),
           CLIPBOARD_ARCHIVE_ARCHIVE_ROOT=str(root/'archive'),
           CLIPBOARD_ARCHIVE_INDEX_PATH=str(root/'index/search.sqlite'),
           CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST=str(root/'agent.plist'),
           CFFIXED_USER_HOME=str(root/'home'), TMPDIR=str(root/'tmp'))
# The filesystem deny also contains implicit AppKit saved-state/cache writes.
# cfprefsd is a separate writer; deny its IPC route, not just file writes.
profile = '(version 1)\n(allow default)\n(deny network-outbound)\n(deny file-write*)\n'
profile += '(allow file-write* (subpath '+json.dumps(str(root))+') (literal "/dev/null"))\n'
profile += '(deny mach-lookup (global-name "com.apple.cfprefsd.agent") (global-name "com.apple.cfprefsd.daemon"))\n'
profile_path = root/'containment.sb'
profile_path.write_text(profile)
print(json.dumps({'support':env['CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT'], 'archive':env['CLIPBOARD_ARCHIVE_ARCHIVE_ROOT'], 'index':env['CLIPBOARD_ARCHIVE_INDEX_PATH'], 'preferences':'support/preferences.json', 'clock':'support/clock.txt', 'containment':str(profile_path)}), flush=True)
os.execve('/usr/bin/sandbox-exec', ['sandbox-exec','-f',str(profile_path),str(executable)], env)
