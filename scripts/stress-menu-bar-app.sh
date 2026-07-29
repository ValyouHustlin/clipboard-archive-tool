#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_ROOT="${1:-/tmp/clipboard-archive-app-stress-archive}"
APP_SUPPORT_ROOT="${ARCHIVE_ROOT}-app-support"
APP_PATH="$ROOT/.build/clipboard-archive-app-stress/ClipboardArchive.app"

if /usr/bin/pgrep -x ClipboardArchive >/dev/null 2>&1 &&
   [ "${CLIPBOARD_ARCHIVE_ALLOW_LIVE_CLIPBOARD_STRESS:-0}" != "1" ]; then
  echo "app stress refused: ClipboardArchive is running and would capture synthetic test clipboard values" >&2
  echo "stop it explicitly or set CLIPBOARD_ARCHIVE_ALLOW_LIVE_CLIPBOARD_STRESS=1 after reviewing the impact" >&2
  exit 2
fi

rm -rf "$ARCHIVE_ROOT"
mkdir -p "$ARCHIVE_ROOT"

cd "$ROOT"
CLIPBOARD_ARCHIVE_APP_OUTPUT="$APP_PATH" ./scripts/build-menu-bar-app.sh >/dev/null

CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$ARCHIVE_ROOT" \
CLIPBOARD_ARCHIVE_INDEX_PATH="$ARCHIVE_ROOT/index.sqlite" \
CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$APP_SUPPORT_ROOT" \
  "$APP_PATH/Contents/MacOS/ClipboardArchive" &
APP_PID=$!

cleanup() {
  printf '%s' 'Clipboard Archive app stress test complete' | pbcopy || true
  if kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

sleep 2
rss_start="$(ps -o rss= -p "$APP_PID" | tr -d ' ')"
fd_start="$(lsof -p "$APP_PID" 2>/dev/null | wc -l | tr -d ' ')"

printf '%s' 'menu app stress ordinary phrase' | pbcopy
sleep 0.2

{
  echo 'struct MenuAppStress {'
  for i in $(seq 1 3000); do
    echo "    let value${i} = \"menu-app-large-body-search-token-${i}\""
  done
  echo '}'
} | pbcopy
sleep 0.8

FAKE_SECRET_VALUE="ghp_"
FAKE_SECRET_VALUE="${FAKE_SECRET_VALUE}fakefakefakefakefakefakefakefakefake"
printf '%s' "FAKE_SECRET_TOKEN=${FAKE_SECRET_VALUE}" | pbcopy
sleep 0.8

for i in $(seq 1 40); do
  printf 'menu-app-rapid-copy-%03d local phrase\n' "$i" | pbcopy
  sleep 0.25
done

sleep 2
rss_end="$(ps -o rss= -p "$APP_PID" | tr -d ' ')"
fd_end="$(lsof -p "$APP_PID" 2>/dev/null | wc -l | tr -d ' ')"

./scripts/check-archive-integrity.sh "$ARCHIVE_ROOT" >/dev/null
"$ROOT/.build/debug/clipboard-archive" search 'menu app stress ordinary phrase' --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'menu app stress ordinary phrase'
"$ROOT/.build/debug/clipboard-archive" search 'menu-app-large-body-search-token-3000' --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'menu-app-large-body-search-token-3000'
"$ROOT/.build/debug/clipboard-archive" search 'menu-app-rapid-copy-040' --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'menu-app-rapid-copy-040'
if "$ROOT/.build/debug/clipboard-archive" search "$FAKE_SECRET_VALUE" --archive-root "$ARCHIVE_ROOT" --limit 1 | grep -q 'ghp_fake'; then
  echo "app stress failed: fake token was searchable" >&2
  exit 1
fi

fd_growth=$((fd_end - fd_start))
rss_growth=$((rss_end - rss_start))
if [ "$fd_growth" -gt 4 ]; then
  echo "app stress failed: file descriptor growth too high start=$fd_start end=$fd_end" >&2
  exit 1
fi

echo "app stress ok"
echo "archive root: $ARCHIVE_ROOT"
echo "rss_kb_start: $rss_start"
echo "rss_kb_end: $rss_end"
echo "rss_kb_growth: $rss_growth"
echo "fd_start: $fd_start"
echo "fd_end: $fd_end"
