#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_ROOT="${1:-/tmp/clipboard-archive-stress-archive}"
LOG_FILE="${ARCHIVE_ROOT}/monitor.log"
rm -rf "$ARCHIVE_ROOT"
mkdir -p "$ARCHIVE_ROOT"

cd "$ROOT"
swift build --product clipboard-archive >/dev/null

"$ROOT/.build/debug/clipboard-archive" monitor \
  --archive-root "$ARCHIVE_ROOT" \
  --interval 0.05 \
  --duration 30 \
  >"$LOG_FILE" 2>&1 &
MONITOR_PID=$!

cleanup() {
  printf '%s' 'Clipboard Archive stress test complete' | pbcopy || true
  if kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep 1

printf '%s' 'alpha local clipboard stress phrase' | pbcopy
sleep 0.2

printf '%s' 'https://example.com/clipboard-stress-url?case=local-only' | pbcopy
sleep 0.2

{
  echo 'func stressExample() {'
  for i in $(seq 1 9000); do
    echo "    let line${i} = \"stress-large-code-search-token-${i}\""
  done
  echo '}'
} | pbcopy
sleep 0.5

FAKE_SECRET_VALUE="sk-"
FAKE_SECRET_VALUE="${FAKE_SECRET_VALUE}fakefakefakefakefakefakefakefakefakefake"
printf '%s' "OPENAI_API_KEY=${FAKE_SECRET_VALUE}" | pbcopy
sleep 1.0

for i in $(seq 1 50); do
  printf 'rapid-copy-item-%03d local-search-token\n' "$i" | pbcopy
  sleep 0.07
done
sleep 1.0

wait "$MONITOR_PID"
trap - EXIT
printf '%s' 'Clipboard Archive stress test complete' | pbcopy || true

stored_count="$(grep -c '^stored ' "$LOG_FILE" || true)"
blocked_count="$(grep -c '^blocked ' "$LOG_FILE" || true)"

"$ROOT/.build/debug/clipboard-archive" search 'alpha local clipboard stress phrase' --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'alpha local clipboard stress phrase'
"$ROOT/.build/debug/clipboard-archive" search 'stress-large-code-search-token-9000' --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'stress-large-code-search-token-9000'
"$ROOT/.build/debug/clipboard-archive" search 'rapid-copy-item-050' --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'rapid-copy-item-050'
if "$ROOT/.build/debug/clipboard-archive" search "$FAKE_SECRET_VALUE" --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'sk-fake'; then
  echo "stress failed: fake secret was searchable" >&2
  exit 1
fi

if [ "$stored_count" -lt 10 ]; then
  echo "stress failed: expected at least 10 stored events, got $stored_count" >&2
  exit 1
fi
if [ "$blocked_count" -lt 1 ]; then
  echo "stress failed: expected at least 1 blocked event, got $blocked_count" >&2
  exit 1
fi

echo "stress ok"
echo "archive root: $ARCHIVE_ROOT"
echo "stored: $stored_count"
echo "blocked: $blocked_count"
