#!/usr/bin/env bash
# Slice 8 receipt harness: encrypted backup round-trip through the REAL CLI
# against a fully synthetic archive in an isolated temp root. Verifies:
#   1. backup create (passphrase via stdin, never argv)
#   2. backup inspect --json (counts match the seeded fixture)
#   3. restore into an empty root -> byte-identical tree + 600/700 modes
#   4. wrong passphrase -> hard failure, zero writes, no staging leftovers
#   5. merge dry-run == execute plan parity (--json)
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== building CLI =="
xcrun swift build --product clipboard-archive >/dev/null
BIN="$ROOT/.build/debug/clipboard-archive"

WORK="$(mktemp -d /tmp/clipboard-backup-roundtrip.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/source-archive"
DST="$WORK/restored-archive"
DST_WRONG="$WORK/wrongpass-archive"
MERGE_TARGET="$WORK/merge-target"
PASS="synthetic-roundtrip-passphrase"
BACKUP="$WORK/roundtrip.clipbak"

echo "== seeding synthetic archive (no live data; authored fixtures only) =="
mkdir -p "$SRC/raw/2026/07/2026-07-30_large-items" "$SRC/deletion-ledger" "$SRC/annotations" "$SRC/manifests"
cat > "$SRC/raw/2026/07/2026-07-30_clipboard-events.ndjson" <<'EOF'
{"allowedUse":["local-search","local-analysis"],"byteCount":25,"capturedAt":"2026-07-30T08:00:00Z","characterCount":25,"contentHash":"sha256:fixture1","contentInline":"synthetic fixture line one","contentPreview":"synthetic fixture line one","contentType":"text","id":"clip_20260730T080000Z_fixture00001_aaaa1111","lineCount":1,"pasteboardTypes":["public.utf8-plain-text"],"privacyLabel":"private-local","sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Notes","name":"Notes"},"uiVisibleUntil":"2026-08-06T08:00:00Z"}
{"allowedUse":["local-search","local-analysis"],"byteCount":25,"capturedAt":"2026-07-30T09:00:00Z","characterCount":25,"contentHash":"sha256:fixture2","contentPreview":"synthetic large body clip","contentType":"text","id":"clip_20260730T090000Z_fixture00002_bbbb2222","lineCount":1,"pasteboardTypes":["public.utf8-plain-text"],"privacyLabel":"private-local","rawContentPath":"raw/2026/07/2026-07-30_large-items/clip_20260730T090000Z_fixture00002_bbbb2222.txt","sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Notes","name":"Notes"},"uiVisibleUntil":"2026-08-06T09:00:00Z"}
{"capturedAt":"2026-07-30T10:00:00Z","contentStored":false,"eventType":"blocked_sensitive_clipboard_item","reason":"source_app_denylist:dashlane","sourceApp":{"name":"Dashlane"}}
EOF
printf 'synthetic large body payload line\n%.0s' $(seq 1 2000) > "$SRC/raw/2026/07/2026-07-30_large-items/clip_20260730T090000Z_fixture00002_bbbb2222.txt"
cat > "$SRC/deletion-ledger/2026-07-30_deletions.ndjson" <<'EOF'
{"clipboardEventID":"clip_20260729T000000Z_deleted00001_cccc3333","deletedAt":"2026-07-30T11:00:00Z","eventType":"clipboard_event_deleted","reason":"manual-delete"}
EOF
cat > "$SRC/annotations/annotations.json" <<'EOF'
{
  "annotations" : {
    "sha256:fixture1" : {
      "pinned" : true,
      "pinnedAt" : "2026-07-30T08:30:00Z",
      "snippet" : false,
      "tags" : [
        "roundtrip"
      ]
    }
  },
  "annotationsVersion" : 1,
  "collections" : [ ],
  "updatedAt" : "2026-07-30T08:30:00Z"
}
EOF
printf '{"synthetic":"daily manifest fixture"}\n' > "$SRC/manifests/2026-07-30_manifest.json"
printf '{"archiveFormatVersion":1,"minReader":1}\n' > "$SRC/archive-format.json"
find "$SRC" -type d -exec chmod 700 {} +
find "$SRC" -type f -exec chmod 600 {} +

echo "== 1. backup create (passphrase over stdin) =="
printf '%s\n' "$PASS" | "$BIN" backup create "$BACKUP" --archive-root "$SRC" --passphrase-stdin

echo "== 2. backup inspect --json =="
INSPECT_JSON="$WORK/inspect.json"
printf '%s\n' "$PASS" | "$BIN" backup inspect "$BACKUP" --json --passphrase-stdin > "$INSPECT_JSON"
python3 - "$INSPECT_JSON" <<'EOF'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
counts = data["manifest"]["counts"]
assert counts["storedEvents"] == 2, counts
assert counts["blockedEvents"] == 1, counts
assert counts["ledgerRecords"] == 1, counts
assert counts["bodyFiles"] == 1, counts
assert counts["annotationRecords"] == 1, counts
assert data["framingIntact"] is True
assert data["iterations"] >= 600000, data["iterations"]
assert data["manifest"]["filesNotIncluded"] == []
print("inspect counts ok: stored=2 blocked=1 ledger=1 bodies=1 annotations=1")
print("pbkdf2 iterations:", data["iterations"])
EOF

echo "== 3. restore into empty root -> byte-identical =="
mkdir -p "$DST"
chmod 700 "$DST"
printf '%s\n' "$PASS" | "$BIN" backup restore "$BACKUP" --archive-root "$DST" --index-path "$WORK/restored.sqlite" --passphrase-stdin
diff -r "$SRC" "$DST"
echo "tree diff: byte-identical"
bad_modes="$(cd "$DST" && find . -mindepth 1 -type f ! -perm 600 -print; cd "$DST" && find . -mindepth 1 -type d ! -perm 700 -print)"
if [ -n "$bad_modes" ]; then
  echo "FAIL: restored entries with wrong modes:" >&2
  echo "$bad_modes" >&2
  exit 1
fi
echo "permissions: files 600, directories 700"

echo "== 4. wrong passphrase -> zero writes =="
mkdir -p "$DST_WRONG"
if printf '%s\n' "not-the-passphrase" | "$BIN" backup restore "$BACKUP" --archive-root "$DST_WRONG" --index-path "$WORK/wrong.sqlite" --passphrase-stdin 2> "$WORK/wrong.err"; then
  echo "FAIL: wrong passphrase restore succeeded" >&2
  exit 1
fi
grep -q "wrong passphrase" "$WORK/wrong.err"
leftovers="$(find "$DST_WRONG" -mindepth 1 | wc -l | tr -d ' ')"
if [ "$leftovers" != "0" ]; then
  echo "FAIL: wrong-passphrase restore wrote $leftovers entries" >&2
  exit 1
fi
echo "wrong passphrase rejected; target untouched; no staging leftovers"

echo "== 5. merge dry-run == execute plan parity =="
mkdir -p "$MERGE_TARGET/raw/2026/07"
# Target already holds fixture1 (overlap) but not fixture2/blocked/ledger.
head -1 "$SRC/raw/2026/07/2026-07-30_clipboard-events.ndjson" > "$MERGE_TARGET/raw/2026/07/2026-07-30_clipboard-events.ndjson"
find "$MERGE_TARGET" -type d -exec chmod 700 {} +
find "$MERGE_TARGET" -type f -exec chmod 600 {} +
printf '%s\n' "$PASS" | "$BIN" backup restore "$BACKUP" --archive-root "$MERGE_TARGET" --index-path "$WORK/merge.sqlite" --merge --dry-run --json --passphrase-stdin > "$WORK/plan-dry.json"
printf '%s\n' "$PASS" | "$BIN" backup restore "$BACKUP" --archive-root "$MERGE_TARGET" --index-path "$WORK/merge.sqlite" --merge --json --passphrase-stdin > "$WORK/plan-exec.json"
python3 - "$WORK/plan-dry.json" "$WORK/plan-exec.json" <<'EOF'
import json, sys
with open(sys.argv[1]) as fh:
    dry = json.load(fh)
with open(sys.argv[2]) as fh:
    execute = json.load(fh)
assert dry["dryRun"] is True and execute["dryRun"] is False
assert dry["plan"] == execute["plan"], (dry["plan"], execute["plan"])
plan = execute["plan"]
assert plan["mode"] == "merge"
assert plan["newEvents"] == 1, plan
assert plan["skippedExistingEvents"] == 1, plan
assert plan["ledgerRecordsToAdd"] == 1, plan
assert plan["bodiesToAdd"] == 1, plan
assert plan["blockedLinesToAppend"] == 1, plan
assert execute["indexRebuildFailed"] is False
print("dry-run plan == execute plan (field-for-field)")
print("merge plan:", json.dumps(plan, sort_keys=True))
EOF

echo "== backup round-trip check ok =="
