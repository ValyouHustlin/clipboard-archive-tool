# Privacy

Clipboard Archive is local-first.

- Clipboard contents are stored on the Mac where the app is installed.
- The app does not send clipboard contents to cloud services.
- The app has no network sync, telemetry, analytics, crash reporting, or
  in-app update checks.
- After install, normal capture/search/archive operation works without an
  internet connection.
- Password managers and credential-like content are blocked by default.
- Blocked sensitive events are recorded without raw content.
- Manual delete/redact removes inline content, removes large body files,
  records a deletion marker, and purges the item from the local SQLite search
  index. Non-content timeline metadata remains so the archive can show that an
  item existed without retaining the copied text.
- Permanent archive tracking can be turned off from the Settings window. When
  it is off, new clipboard changes are not written to durable history.
- Archive and index locations are controlled by environment variables in the
  LaunchAgent:
  - `CLIPBOARD_ARCHIVE_ARCHIVE_ROOT`
  - `CLIPBOARD_ARCHIVE_INDEX_PATH`

Known limits:

- macOS exposes clipboard changes as a pasteboard change count, not a queue.
  A value overwritten before the app polls cannot be recovered.
- Source app attribution is best-effort.
- Browser password fields are not reliably detectable without deeper
  Accessibility inspection.
- Unsigned local builds may require macOS Gatekeeper approval on first launch.
