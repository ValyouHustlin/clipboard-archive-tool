#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_ROOT="${1:-/tmp/clipboard-archive-stress-archive}"
LOG_FILE="${ARCHIVE_ROOT}/monitor.log"

if /usr/bin/pgrep -x ClipboardArchive >/dev/null 2>&1 &&
   [ "${CLIPBOARD_ARCHIVE_ALLOW_LIVE_CLIPBOARD_STRESS:-0}" != "1" ]; then
  echo "stress refused: ClipboardArchive is running and would capture synthetic test clipboard values" >&2
  echo "stop it explicitly or set CLIPBOARD_ARCHIVE_ALLOW_LIVE_CLIPBOARD_STRESS=1 after reviewing the impact" >&2
  exit 2
fi

# The run deletes its root first, so it only ever uses a scratch directory.
case "$ARCHIVE_ROOT" in
  /tmp/*|/private/tmp/*) ;;
  *)
    echo "refusing to run outside /tmp: $ARCHIVE_ROOT" >&2
    exit 2
    ;;
esac

rm -rf "$ARCHIVE_ROOT"
mkdir -p "$ARCHIVE_ROOT"
# Every store the CLI resolves stays inside the scratch root. Each path is
# resolved on its own, so an archive root alone sent these synthetic clips
# into the real search index.
export CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$ARCHIVE_ROOT"
export CLIPBOARD_ARCHIVE_INDEX_PATH="$ARCHIVE_ROOT/index.sqlite"
export CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$ARCHIVE_ROOT/support"
export CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST="$ARCHIVE_ROOT/agent.plist"

cd "$ROOT"
/usr/bin/xcrun swift build --product clipboard-archive >/dev/null

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
