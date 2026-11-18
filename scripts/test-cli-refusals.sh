#!/usr/bin/env bash
# The command-line tool refuses, with exit 2 and before doing anything, the
# command lines that used to delete or write when the caller meant otherwise.
# Runs against a scratch archive only.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${CLIPBOARD_ARCHIVE_TEST_CLI:-}"
if [ -z "$CLI" ]; then
  (cd "$ROOT" && /usr/bin/xcrun swift build --product clipboard-archive >/dev/null)
  CLI="$ROOT/.build/debug/clipboard-archive"
fi

T="$(/usr/bin/mktemp -d /tmp/clipboard-archive-cli-refusals.XXXXXX)"
trap '/bin/rm -rf "$T"' EXIT
export CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$T/support"
export CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$T/archive"
export CLIPBOARD_ARCHIVE_INDEX_PATH="$T/index/search.sqlite"
export CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST="$T/agent.plist"

CLIP_ID="clip_20270115T080000Z_fda6d439ff6a_7f2e8e69"
/bin/mkdir -p "$T/archive/raw/2027/01"
/usr/bin/printf '%s\n' '{"allowedUse":["local-search","local-analysis"],"byteCount":38,"capturedAt":"2027-01-15T08:00:00Z","characterCount":38,"contentHash":"sha256:fda6d439ff6a949835766599e123baae0d18e8794eaf314db842bec861206fe5","contentInline":"Clipboard Archive local self-test note","contentPreview":"Clipboard Archive local self-test note","contentType":"text","id":"clip_20270115T080000Z_fda6d439ff6a_7f2e8e69","lineCount":1,"pasteboardTypes":["public.utf8-plain-text"],"privacyLabel":"private-local","sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Safari","name":"Safari"},"uiVisibleUntil":"2027-01-22T08:00:00Z"}' \
  > "$T/archive/raw/2027/01/2027-01-15_clipboard-events.ndjson"
before="$(/usr/bin/shasum -a 256 "$T/archive/raw/2027/01/2027-01-15_clipboard-events.ndjson")"

failures=0
expect_exit() { # wanted exit code, description, then the arguments
  local wanted="$1" description="$2" got=0; shift 2
  "$CLI" "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" = "$wanted" ]; then echo "ok   - $description"; else echo "FAIL - $description (exit $got, wanted $wanted)" >&2; failures=$((failures + 1)); fi
}

expect_exit 2 "prune refuses --since as its cutoff" prune --since 2030-01-01
expect_exit 2 "redact refuses --dry-run" redact "$CLIP_ID" --dry-run
expect_exit 2 "sweep-expired refuses --dry-run" sweep-expired --dry-run
expect_exit 2 "export refuses --dry-run" export --out "$T/out.ndjson" --dry-run
expect_exit 2 "backup with no subcommand is a usage error" backup
expect_exit 0 "a bulk range with since after until matches nothing instead of crashing" bulk --since 2027-02-01 --until 2027-01-01 --dry-run

if [ "$(/usr/bin/shasum -a 256 "$T/archive/raw/2027/01/2027-01-15_clipboard-events.ndjson")" = "$before" ] && [ ! -e "$T/out.ndjson" ]; then
  echo "ok   - nothing was deleted or written by the refused commands"
else
  echo "FAIL - a refused command changed the archive or wrote a file" >&2; failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "cli refusal test failed: $failures check(s)" >&2
  exit 1
fi
echo "cli refusal test ok"
