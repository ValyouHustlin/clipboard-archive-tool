# clipboard-archive

Every command in the Clipboard Archive command-line tool.

This file is generated: `clipboard-archive help --markdown` prints it, and a
test regenerates it and fails if the committed copy has drifted.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | runtime failure |
| 2 | usage error |
| 3 | store missing or unreadable |
| 4 | problems found |
| 5 | completed with warnings |

Under `--json`, a failure prints `{"error":{"code":…,"message":…}}` to
standard error, where the code is `usage`, `runtime`, `store` or `integrity`.

## Store options

Every command accepts these:

- `--archive-root PATH` — Archive location. Resolved in order: this flag, CLIPBOARD_ARCHIVE_ARCHIVE_ROOT, the pointer the running app published, the per-user default.
- `--index-path PATH` — Search index location, resolved the same four ways. Run `stores` to see which one won.

## Commands

### help

Describe the commands, or one command in detail.

```
clipboard-archive help [VERB] [--markdown]
```

- `--markdown` — Print the full reference as Markdown (this is what docs/CLI.md holds).

### version

Print the application and CLI version, the index schema and the archive format.

```
clipboard-archive version [--json]
```

- `--json` — Print the result as one JSON object carrying a `schema` number.

### stores

Report which archive, index, settings, lock and pointer file this command resolved, and where each came from.

```
clipboard-archive stores [--json]
```

- `--json` — Print the result as one JSON object carrying a `schema` number.

### status

Answer whether capture is alive right now, in one fast read.

```
clipboard-archive status [--json]
```

Reads the lock file's holder to decide whether the app is running — never launchctl, which reports the launcher's exit and not the app's life. Exits 5 when something is worth saying (a heartbeat that has gone quiet, a launch agent pointing at a path that is not there, a plist that pins stores other than the resolved ones) and 3 when the stores are missing.

- `--json` — Print the result as one JSON object carrying a `schema` number.

### health

Report archive and index counts, sizes and dates.

```
clipboard-archive health [--json]
```

- `--json` — Print the result as one JSON object carrying a `schema` number.

### verify

Check the archive and the index against each other and report every problem found.

```
clipboard-archive verify [--json]
```

The slow, complete counterpart to `status`: every health metric, an integrity check of the index database, and a membership comparison between the events the archive holds and the rows the index holds, in both directions. Exits 4 when anything is wrong.

- `--json` — Print the result as one JSON object carrying a `schema` number.

### doctor

Run the store, status and verify checks and explain the result in plain English.

```
clipboard-archive doctor [--json]
```

Exits with the worst of its parts' exit codes.

- `--json` — Print the result as one JSON object carrying a `schema` number.

### search

Search the archive through the search index, with the matcher the history window uses.

```
clipboard-archive search QUERY [--scan] [--json] [filters]
```

- `--since DATE` — Lower bound, ISO 8601 or YYYY-MM-DD.
- `--until DATE` — Upper bound, ISO 8601 or YYYY-MM-DD.
- `--app NAME` — Only clips copied from this application.
- `--bundle-id ID` — Only clips copied from this bundle identifier.
- `--type TYPE` — Only clips of this content type (text, url, code, image, file-list).
- `--limit N` — Stop after this many results.
- `--scan` — Read the raw day files instead of the index: slower, but it works with no index at all.
- `--json` — Print the result as one JSON object carrying a `schema` number.

### index-search

Deprecated alias for `search`.

```
clipboard-archive index-search QUERY [--limit N]
```

- `--json` — Print the result as one JSON object carrying a `schema` number.

### export

Write matching clips, with their content, to a file you name.

```
clipboard-archive export --out PATH [--format ndjson|json] [--force] [filters]
```

The file holds real clipboard content, so it is written with owner-only permissions and never to standard output, and the command prints counts rather than what it wrote. Clips labelled restricted, clips marked restricted by hand, and clips that have been deleted or suppressed are left out.

- `--since DATE` — Lower bound, ISO 8601 or YYYY-MM-DD.
- `--until DATE` — Upper bound, ISO 8601 or YYYY-MM-DD.
- `--app NAME` — Only clips copied from this application.
- `--bundle-id ID` — Only clips copied from this bundle identifier.
- `--type TYPE` — Only clips of this content type (text, url, code, image, file-list).
- `--limit N` — Stop after this many results.
- `--out PATH` — Required. The file to write. Standard output is refused: this content is not for a terminal or a pipe.
- `--format FORMAT` — ndjson (default) or json.
- `--force` — Overwrite an existing file.
- `--json` — Print the result as one JSON object carrying a `schema` number.

### stats

Summarise the usage and operational logs by day.

```
clipboard-archive stats [--since DATE] [--json]
```

- `--since DATE` — Only rows at or after this date.
- `--json` — Print the result as one JSON object carrying a `schema` number.

### logs

Print the operational log: launches, heartbeats, capture failures, rebuilds, prunes.

```
clipboard-archive logs [--tail N] [--errors] [--since DATE] [--json]
```

- `--tail N` — How many rows to print. Default: 50.
- `--errors` — Only rows recorded at error level.
- `--since DATE` — Only rows at or after this date.
- `--json` — Print the result as one JSON object carrying a `schema` number.

### monitor

Poll the pasteboard and archive accepted text changes until stopped.

```
clipboard-archive monitor [--interval SECONDS] [--duration SECONDS] [--verbose]
```

Exits 5 if the archive stored a clip that the index did not take.

- `--interval SECONDS` — Polling interval. Default: 1.
- `--duration SECONDS` — Stop after this many seconds.
- `--inline-limit-bytes BYTES` — Content larger than this goes to a body file. Default: 65536.
- `--verbose` — Print ignored non-text changes.

### repair-index

Rebuild the derived search index from the archive.

```
clipboard-archive repair-index
```

### redact

Remove the stored content of one clip, keeping its record.

```
clipboard-archive redact ID
```

### prune

Remove stored content older than a cutoff.

```
clipboard-archive prune --until DATE [--dry-run] [--include-pinned] [--json]
```

- `--until DATE` — The cutoff. Content captured before it is removed.
- `--dry-run` — Report the impact without changing anything.
- `--include-pinned` — Prune pinned clips too. They are exempt by default.
- `--json` — Print the result as one JSON object carrying a `schema` number.

### bulk

Delete clips by date, application, type or sensitivity.

```
clipboard-archive bulk [criteria] [--dry-run] [--json]
```

- `--since DATE` — Criterion: captured at or after.
- `--until DATE` — Criterion: captured before.
- `--app NAME` — Criterion: source application name.
- `--bundle-id ID` — Criterion: source bundle identifier.
- `--type TYPE` — Criterion: content type.
- `--sensitivity KIND` — Criterion: any-flagged or manual-restricted.
- `--include-pinned` — Delete pinned clips too. They are exempt by default.
- `--dry-run` — Preview. Execution is not undoable.
- `--json` — Print the result as one JSON object carrying a `schema` number.

### sweep-expired

Delete clips whose sensitivity expiry has passed.

```
clipboard-archive sweep-expired [--json]
```

- `--json` — Print the result as one JSON object carrying a `schema` number.

### backup

Create, inspect or restore an encrypted backup of the archive.

```
clipboard-archive backup create|inspect|restore FILE [options]
```

- `--include-settings` — create: include the settings file.
- `--passphrase-stdin` — Read the passphrase from standard input.
- `--merge` — restore: import missing items into a non-empty archive. Local deletions always win.
- `--apply-settings` — restore: apply the backed-up settings.
- `--dry-run` — restore: report the plan without writing.
- `--json` — Print the result as one JSON object carrying a `schema` number.

### write-manifest

Write today's daily manifest.

```
clipboard-archive write-manifest
```

### self-test

Write one sample event to a temporary directory and report where.

```
clipboard-archive self-test
```
