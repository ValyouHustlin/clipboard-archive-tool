import ClipboardArchiveCore
import AppKit
import Foundation
import UniformTypeIdentifiers

/// Slice 8 UI: "Back Up Archive…" and "Restore from Backup…" flows.
///
/// - Save/open panels for `.clipbak` containers.
/// - Passphrase entry through secure fields only (never logged, never put
///   in window titles or error text).
/// - All crypto/IO runs off the main thread with a determinate progress
///   panel; the UI thread only ever renders.
/// - Restore shows the decrypted-manifest preview with the FULL
///   planned-action counts (the same plan the commit executes) before
///   anything is written; the post-import archive-mutation hook fires via
///   `onArchiveMutated`.
@MainActor
final class ClipboardBackupUIController: NSObject {
    private let archiveRoot: URL
    private let indexURL: URL
    private let onArchiveMutated: () -> Void
    private var isBusy = false

    private var progressWindow: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var progressLabel: NSTextField?

#if DEBUG
    /// Last preview window shown (render receipts for isolated harnesses).
    private(set) var lastPreviewWindow: NSWindow?
#endif

    init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL(),
        onArchiveMutated: @escaping () -> Void
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
        self.onArchiveMutated = onArchiveMutated
        super.init()
    }

    // MARK: - Back up

    func runBackup() {
        guard !isBusy else {
            return
        }
        let panel = NSSavePanel()
        panel.title = "Back Up Clipboard Archive"
        if let type = UTType(filenameExtension: ClipboardBackupFormat.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Clipboard Archive Backup \(dayFormatter.string(from: Date())).\(ClipboardBackupFormat.fileExtension)"
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        guard let entry = promptForCreatePassphrase() else {
            return
        }
        let enteredPassphrase = entry.passphrase
        let includeSettings = entry.includeSettings

        isBusy = true
        showProgress(title: "Backing Up Archive…")
        let archiveRoot = archiveRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var passphrase = enteredPassphrase
            var result: Result<ClipboardBackupExporter.Result, Error>
            do {
                _ = try ClipboardBackupImporter.recoverStaleStaging(archiveRoot: archiveRoot)
                let exporter = ClipboardBackupExporter(archiveRoot: archiveRoot)
                let exported = try exporter.export(
                    to: destination,
                    passphrase: passphrase,
                    includeSettings: includeSettings,
                    progress: { done, total in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.updateProgress(done: done, total: total)
                            }
                        }
                    }
                )
                result = .success(exported)
            } catch {
                result = .failure(error)
            }
            ClipboardBackupPassphrase.zero(&passphrase)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.hideProgress()
                    self.isBusy = false
                    switch result {
                    case let .success(exported):
                        let alert = NSAlert()
                        alert.messageText = "Backup Created"
                        var lines = [
                            "Saved to \(exported.outputURL.path)",
                            "\(exported.manifest.counts.storedEvents) clips, \(exported.manifest.counts.bodyFiles) large bodies, \(exported.manifest.counts.annotationRecords) annotations.",
                            "Settings included: \(exported.manifest.includesSettings ? "yes" : "no")."
                        ]
                        if !exported.manifest.filesNotIncluded.isEmpty {
                            lines.append(
                                "Not included (unknown files): "
                                    + exported.manifest.filesNotIncluded.joined(separator: ", ")
                            )
                        }
                        alert.informativeText = lines.joined(separator: "\n")
                        alert.runModal()
                    case let .failure(error):
                        self.showError(title: "Backup Failed", error: error)
                    }
                }
            }
        }
    }

    // MARK: - Restore

    func runRestore() {
        guard !isBusy else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Restore from Backup"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: ClipboardBackupFormat.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let backupFileURL = panel.url else {
            return
        }
        guard let enteredPassphrase = promptForRestorePassphrase() else {
            return
        }

        isBusy = true
        showProgress(title: "Verifying Backup…")
        let importer = ClipboardBackupImporter(archiveRoot: archiveRoot, indexURL: indexURL)
        let merge = !Self.archiveLooksEmpty(archiveRoot: archiveRoot)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var passphrase = enteredPassphrase
            var result: Result<ClipboardBackupPreparedImport, Error>
            do {
                let prepared = try importer.plan(
                    backupFileURL: backupFileURL,
                    passphrase: passphrase,
                    options: ClipboardBackupImportOptions(merge: merge),
                    progress: { done, total in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.updateProgress(done: done, total: total)
                            }
                        }
                    }
                )
                result = .success(prepared)
            } catch {
                result = .failure(error)
            }
            ClipboardBackupPassphrase.zero(&passphrase)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.hideProgress()
                    switch result {
                    case let .success(prepared):
                        self.presentPreview(prepared, importer: importer)
                    case let .failure(error):
                        self.isBusy = false
                        self.showError(title: "Restore Failed", error: error)
                    }
                }
            }
        }
    }

    private func presentPreview(_ prepared: ClipboardBackupPreparedImport, importer: ClipboardBackupImporter) {
        let window = makePreviewWindow(plan: prepared.plan, manifest: prepared.manifest)
#if DEBUG
        lastPreviewWindow = window
#endif
        NSApp.activate(ignoringOtherApps: true)
        let response = NSApp.runModal(for: window)
        window.orderOut(nil)
        guard response == .OK else {
            importer.discard(prepared)
            isBusy = false
            return
        }

        showProgress(title: "Restoring Backup…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<ClipboardBackupImportOutcome, Error>
            do {
                result = .success(try importer.commit(prepared))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.hideProgress()
                    self.isBusy = false
                    switch result {
                    case let .success(outcome):
                        // Post-import archive-mutation hook: picker caches
                        // are dirty, retention estimates stale, panel needs
                        // a reload.
                        self.onArchiveMutated()
                        let alert = NSAlert()
                        alert.messageText = "Restore Complete"
                        var lines = [
                            "\(outcome.plan.newEvents) clips imported, \(outcome.plan.skippedExistingEvents) already present, \(outcome.plan.skippedDeletedHere) skipped (deleted here)."
                        ]
                        if outcome.indexRebuildFailed {
                            lines.append("Search index rebuild failed — use Maintenance > Rebuild Search Index. Archive data is intact.")
                        }
                        alert.informativeText = lines.joined(separator: "\n")
                        alert.runModal()
                    case let .failure(error):
                        self.onArchiveMutated()
                        self.showError(title: "Restore Failed (rolled back)", error: error)
                    }
                }
            }
        }
    }

    // MARK: - Preview window

    private func makePreviewWindow(
        plan: ClipboardBackupImportPlan,
        manifest: ClipboardBackupManifest
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Restore Preview"

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let title = NSTextField(labelWithString: "Backup from \(formatter.string(from: manifest.createdAt))")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            plan.mode == "merge"
                ? "Merging into the existing archive. Local deletions always win; nothing you deleted comes back."
                : "Restoring into an empty archive."
        )
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        var rows: [(String, String)] = [
            ("Clips to import", "\(plan.newEvents)"),
            ("Already present (skipped)", "\(plan.skippedExistingEvents)"),
            ("Skipped (deleted here)", "\(plan.skippedDeletedHere)"),
            ("Tombstones to import", "\(plan.newTombstones)"),
            ("Deletion records to add", "\(plan.ledgerRecordsToAdd)"),
            ("Local clips newly suppressed", "\(plan.locallyLiveNewlySuppressed)"),
            ("Blocked-event lines to append", "\(plan.blockedLinesToAppend)"),
            ("Large bodies to add", "\(plan.bodiesToAdd)"),
            ("Bodies already identical", "\(plan.bodiesSkippedIdentical)"),
            ("Annotations to add", "\(plan.annotationsAdded)"),
            ("Annotations to merge", "\(plan.annotationsMerged)"),
            ("Annotation conflicts (local wins)", "\(plan.annotationConflictsLocalWins)"),
            ("Collections to add", "\(plan.collectionsAdded)"),
            ("Collections merged", "\(plan.collectionsMergedByID)"),
            ("Collections renamed", "\(plan.collectionsRenamed)")
        ]
        if plan.unreadableLines > 0 {
            rows.append(("Unreadable lines (skipped)", "\(plan.unreadableLines)"))
        }
        if plan.includesSettings {
            rows.append(("Includes app settings", "yes (apply via CLI --apply-settings)"))
        }
        if !plan.filesNotIncludedInBackup.isEmpty {
            rows.append(("Files the backup did not include", plan.filesNotIncludedInBackup.joined(separator: ", ")))
        }

        let grid = NSGridView()
        grid.rowSpacing = 5
        grid.columnSpacing = 14
        for (name, value) in rows {
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .systemFont(ofSize: 12)
            nameLabel.textColor = .secondaryLabelColor
            let valueLabel = NSTextField(labelWithString: value)
            valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            grid.addRow(with: [nameLabel, valueLabel])
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(previewCancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel("Cancel the import")
        let confirm = NSButton(title: "Import", target: self, action: #selector(previewConfirm))
        confirm.keyEquivalent = "\r"
        confirm.toolTip = "Apply exactly the plan shown above"
        confirm.setAccessibilityLabel("Import the backup as previewed")
        let buttons = NSStackView(views: [cancel, confirm])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [title, subtitle, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(16, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.center()
        return window
    }

    @objc private func previewCancel() {
        NSApp.stopModal(withCode: .cancel)
    }

    @objc private func previewConfirm() {
        NSApp.stopModal(withCode: .OK)
    }

#if DEBUG
    func writePreviewSnapshot(to url: URL) throws {
        guard let view = lastPreviewWindow?.contentView else {
            return
        }
        view.layoutSubtreeIfNeeded()
        lastPreviewWindow?.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try data.write(to: url, options: [.atomic])
    }
#endif

    // MARK: - Passphrase entry

    private struct CreatePassphraseEntry {
        var passphrase: Data
        var includeSettings: Bool
    }

    private func promptForCreatePassphrase() -> CreatePassphraseEntry? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Choose a Backup Passphrase"
            alert.informativeText = "At least \(ClipboardBackupFormat.passphraseMinimumLength) characters. The passphrase is required to restore this backup and is not stored anywhere."
            let first = NSSecureTextField(frame: NSRect(x: 0, y: 62, width: 280, height: 24))
            first.placeholderString = "Passphrase"
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 32, width: 280, height: 24))
            second.placeholderString = "Repeat passphrase"
            let includeSettings = NSButton(
                checkboxWithTitle: "Include app settings (off by default — they name excluded apps)",
                target: nil,
                action: nil
            )
            includeSettings.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            includeSettings.font = .systemFont(ofSize: 11)
            includeSettings.setAccessibilityLabel("Include app settings in the backup")
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
            accessory.addSubview(first)
            accessory.addSubview(second)
            accessory.addSubview(includeSettings)
            alert.accessoryView = accessory
            alert.window.initialFirstResponder = first
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
            }
            let value = first.stringValue
            guard value.utf8.count >= ClipboardBackupFormat.passphraseMinimumLength else {
                showValidation("The passphrase must be at least \(ClipboardBackupFormat.passphraseMinimumLength) characters.")
                continue
            }
            guard value == second.stringValue else {
                showValidation("The passphrases did not match.")
                continue
            }
            return CreatePassphraseEntry(
                passphrase: Data(value.utf8),
                includeSettings: includeSettings.state == .on
            )
        }
    }

    private func promptForRestorePassphrase() -> Data? {
        let alert = NSAlert()
        alert.messageText = "Backup Passphrase"
        alert.informativeText = "Enter the passphrase this backup was created with."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return Data(field.stringValue.utf8)
    }

    private func showValidation(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Try Again"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Progress

    private func showProgress(title: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 92),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Archive"
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.startAnimation(nil)
        let stack = NSStackView(views: [label, indicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            indicator.widthAnchor.constraint(equalToConstant: 300)
        ])
        window.contentView = content
        window.center()
        window.orderFrontRegardless()
        progressWindow = window
        progressIndicator = indicator
        progressLabel = label
    }

    private func updateProgress(done: Int64, total: Int64) {
        guard let indicator = progressIndicator, total > 0 else {
            return
        }
        indicator.isIndeterminate = false
        indicator.maxValue = Double(total)
        indicator.doubleValue = Double(done)
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressIndicator = nil
        progressLabel = nil
    }

    // MARK: - Helpers

    /// Mirror of the importer's empty-archive rule, used only to choose the
    /// default mode; the importer re-validates before writing anything.
    static func archiveLooksEmpty(archiveRoot: URL) -> Bool {
        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let eventFiles = (try? reader.eventFiles()) ?? []
        guard eventFiles.isEmpty else {
            return false
        }
        let ledger = archiveRoot.appendingPathComponent("deletion-ledger")
        let ledgerEntries = (try? FileManager.default.contentsOfDirectory(atPath: ledger.path)) ?? []
        guard ledgerEntries.filter({ !$0.hasPrefix(".") }).isEmpty else {
            return false
        }
        let annotations = ClipboardAnnotationsStore(archiveRoot: archiveRoot).annotationsFileURL
        return !FileManager.default.fileExists(atPath: annotations.path)
    }
}
