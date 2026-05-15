#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COUNT="${1:-50000}"
ARCHIVE_ROOT="${2:-/tmp/clipboard-archive-scale-benchmark}"
INDEX_PATH="$ARCHIVE_ROOT/index/clipboard-search.sqlite"

rm -rf "$ARCHIVE_ROOT"
mkdir -p "$ARCHIVE_ROOT"
cd "$ROOT"
swift build --product clipboard-archive >/dev/null

start_generate="$(date +%s)"
"$ROOT/.build/debug/clipboard-archive" self-test >/dev/null

python3 - "$ARCHIVE_ROOT" "$COUNT" <<'PY'
import datetime as dt
import json
import os
import sys

root = sys.argv[1]
count = int(sys.argv[2])
raw_dir = os.path.join(root, "raw", "2026", "01")
os.makedirs(raw_dir, exist_ok=True)
path = os.path.join(raw_dir, "2026-01-01_clipboard-events.ndjson")
base = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)

with open(path, "w", encoding="utf-8") as f:
    for i in range(count):
        captured = base + dt.timedelta(seconds=i)
        body = f"synthetic clipboard benchmark item {i} benchmark-search-token-{i % 997}"
        event = {
            "allowedUse": ["local-search", "local-analysis"],
            "byteCount": len(body.encode("utf-8")),
            "capturedAt": captured.isoformat().replace("+00:00", "Z"),
            "characterCount": len(body),
            "contentHash": f"sha256:synthetic{i}",
            "contentInline": body,
            "contentPreview": body,
            "contentType": "text",
            "id": f"clip_synthetic_{i}",
            "lineCount": 1,
            "pasteboardTypes": ["public.utf8-plain-text"],
            "privacyLabel": "private-local",
            "rawContentPath": None,
            "sensitivityFlags": [],
            "sourceApp": {"name": "Synthetic", "bundleIdentifier": "local.synthetic"},
            "uiVisibleUntil": (captured + dt.timedelta(days=7)).isoformat().replace("+00:00", "Z"),
        }
        f.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
end_generate="$(date +%s)"

start_index="$(date +%s)"
"$ROOT/.build/debug/clipboard-archive" repair-index --archive-root "$ARCHIVE_ROOT" >/tmp/clipboard-archive-scale-index.out
end_index="$(date +%s)"

start_search="$(date +%s)"
"$ROOT/.build/debug/clipboard-archive" search 'benchmark-search-token-42' --archive-root "$ARCHIVE_ROOT" --limit 5 >/tmp/clipboard-archive-scale-search.out
end_search="$(date +%s)"

./scripts/check-archive-integrity.sh "$ARCHIVE_ROOT" >/tmp/clipboard-archive-scale-integrity.out

echo "scale benchmark ok"
echo "archive root: $ARCHIVE_ROOT"
echo "events: $COUNT"
echo "generate_seconds: $((end_generate - start_generate))"
echo "index_seconds: $((end_index - start_index))"
echo "search_seconds: $((end_search - start_search))"
cat /tmp/clipboard-archive-scale-integrity.out
