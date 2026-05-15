#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_ROOT="${1:-${CLIPBOARD_ARCHIVE_ARCHIVE_ROOT:-$HOME/Library/Application Support/ClipboardArchive/Archive/clipboard-history}}"

python3 - "$ARCHIVE_ROOT" <<'PY'
import json
import os
import sys

archive_root = sys.argv[1]
raw_root = os.path.join(archive_root, "raw")

if not os.path.isdir(archive_root):
    print(f"archive integrity failed: missing archive root {archive_root}", file=sys.stderr)
    sys.exit(1)

event_files = 0
stored_events = 0
blocked_events = 0
invalid_json = 0
missing_bodies = 0

for root, _, files in os.walk(raw_root) if os.path.isdir(raw_root) else []:
    for name in files:
        if not name.endswith("_clipboard-events.ndjson"):
            continue
        event_files += 1
        path = os.path.join(root, name)
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except Exception:
                    invalid_json += 1
                    continue
                if event.get("eventType") == "blocked_sensitive_clipboard_item":
                    blocked_events += 1
                    continue
                stored_events += 1
                raw_path = event.get("rawContentPath")
                if raw_path and not os.path.isfile(os.path.join(archive_root, raw_path)):
                    print(f"missing body: {os.path.join(archive_root, raw_path)}", file=sys.stderr)
                    missing_bodies += 1

if invalid_json or missing_bodies:
    print(f"archive integrity failed: invalid_json={invalid_json} missing_bodies={missing_bodies}", file=sys.stderr)
    sys.exit(1)

print("archive integrity ok")
print(f"archive root: {archive_root}")
print(f"event files: {event_files}")
print(f"stored events: {stored_events}")
print(f"blocked events: {blocked_events}")
PY
