import ClipboardArchiveCore
import AppKit
import Foundation

/// Storage & Health dashboard (Slice 5). A separate window — Settings is
/// full — reached from Maintenance ▸ Storage & Health… (replacing the old
/// health NSAlert) and the Local Storage card's button. Sections:
/// Overview (extended health, computed off-main), Recent Blocked Items
/// (humanized reasons), Maintenance (rebuild with an inline receipt +
/// integrity verification), Cleanup (prune-by-age preview→delete through
/// the bulk engine, plus the Bulk Cleanup sheet).
@MainActor
final class ClipboardDashboardWindowController: NSWindowController {
    private let archiveRoot: URL
    private let reader: ClipboardArchiveReader
    private let derivedIndex: ClipboardDerivedIndex
    /// Fired after ANY destructive operation this window performs so the
    /// app invalidates warm caches and refreshes History.
    private let onArchiveMutated: () -> Void

    /// Serial background queue for health scans, previews, and deletions —
    /// the main thread never scans the archive.
    private let workQueue = DispatchQueue(label: "app.clipboardarchive.dashboard")
    private var workInFlight = false

    private let overviewGrid = NSStackView()
    private let blockedList = NSStackView()
    private let maintenanceReceipt = NSTextField(wrappingLabelWithString: " ")
    private let cleanupAgePopup = NSPopUpButton()
    private let cleanupResultLabel = NSTextField(wrappingLabelWithString: " ")
    private let cleanupPreviewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let cleanupDeleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var bulkSheetController: ClipboardBulkSheetController?
    /// Cleanup preview validity: Delete stays disabled until a preview ran
    /// for the CURRENT popup selection; changing it invalidates.
    private var previewedCleanupCutoffIndex: Int?
    private var lastCleanupPreview: ClipboardBulkResult?
    private var lastHealth: ClipboardArchiveHealth?
    private var lastBlockedExplanations: [String] = []

    private static let cleanupChoices: [(title: String, days: Int)] = [
        ("Older than 7 days", 7),
        ("Older than 30 days", 30),
        ("Older than 90 days", 90),
        ("Older than 1 year", 365)
    ]

    init(archiveRoot: URL, onArchiveMutated: @escaping () -> Void = {}) {
        self.archiveRoot = archiveRoot
        self.reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        self.derivedIndex = ClipboardDerivedIndex(archiveRoot: archiveRoot)
        self.onArchiveMutated = onArchiveMutated

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Storage & Health"
        window.minSize = NSSize(width: 640, height: 520)
        window.setFrameAutosaveName("ClipboardDashboardWindow")
        super.init(window: window)
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(activate: Bool = true) {
        refresh()
        window?.center()
        if activate {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFrontRegardless()
        }
    }

#if DEBUG
    func writeSnapshot(to url: URL) throws {
        guard let view = window?.contentView else {
            return
        }
        // Appearance-resolved background fill for faithful light/dark
        // snapshots (Slice 9; see ClipboardPanelController.writeSnapshot).
        view.wantsLayer = true
        window?.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        view.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try data.write(to: url, options: [.atomic])
    }

    var automationIsSettled: Bool {
        !workInFlight
    }

    var automationHealthFacts: [String: Any] {
        guard let health = lastHealth else {
            return [:]
        }
        return [
            "storedEvents": health.storedEvents,
            "blockedEvents": health.blockedEvents,
            "restrictedEvents": health.restrictedEvents,
            "pinnedItems": health.pinnedItems,
            "expiringItems": health.expiringItems,
            "eventFileCount": health.eventFileCount,
            "indexUserVersion": health.indexUserVersion ?? -1,
            "annotationsBytes": Int(health.annotationsBytes),
            "bodyFileBytes": Int(health.bodyFileBytes)
        ]
    }

    var automationBlockedExplanations: [String] {
        lastBlockedExplanations
    }

    var automationCleanupResultText: String {
        cleanupResultLabel.stringValue
    }

    var automationDeleteEnabled: Bool {
        cleanupDeleteButton.isEnabled
    }

    var automationBulkSheet: ClipboardBulkSheetController? {
        bulkSheetController
    }

    func performAutomationCleanupChoice(_ index: Int) {
        cleanupAgePopup.selectItem(at: index)
        cleanupCriteriaChanged()
    }

    func performAutomationCleanupPreview() {
        previewCleanup()
    }

    func performAutomationOpenBulkSheet() {
        openBulkSheet()
    }
#endif

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scroll)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        // Overview card.
        overviewGrid.orientation = .vertical
        overviewGrid.alignment = .leading
        overviewGrid.spacing = 5
        let overviewCard = card(
            title: "Overview",
            subtitle: "Local archive, index, and annotation storage at a glance.",
            symbol: "internaldrive.fill",
            tint: .systemGreen,
            views: [overviewGrid]
        )

        // Recent blocked items card.
        blockedList.orientation = .vertical
        blockedList.alignment = .leading
        blockedList.spacing = 7
        let blockedCard = card(
            title: "Recent Blocked Items",
            subtitle: "Items privacy filters kept out of the archive. Content is never stored for these.",
            symbol: "hand.raised.fill",
            tint: .systemRed,
            views: [blockedList]
        )

        // Maintenance card.
        let rebuildButton = NSButton(title: "Rebuild Search Index", target: self, action: #selector(rebuildIndexClicked))
        rebuildButton.toolTip = "Rebuild the derived search index from the archive (always safe)"
        rebuildButton.setAccessibilityLabel("Rebuild the search index")
        let verifyButton = NSButton(title: "Verify Integrity", target: self, action: #selector(verifyIntegrityClicked))
        verifyButton.toolTip = "Run a SQLite quick_check plus an archive health summary"
        verifyButton.setAccessibilityLabel("Verify archive and index integrity")
        let maintenanceRow = NSStackView(views: [rebuildButton, verifyButton, NSView()])
        maintenanceRow.orientation = .horizontal
        maintenanceRow.spacing = 9
        maintenanceReceipt.font = .systemFont(ofSize: 11)
        maintenanceReceipt.textColor = .secondaryLabelColor
        let maintenanceCard = card(
            title: "Maintenance",
            subtitle: "The search index is disposable derived data; rebuilding it is always safe.",
            symbol: "wrench.and.screwdriver.fill",
            tint: .systemOrange,
            views: [maintenanceRow, maintenanceReceipt]
        )

        // Cleanup card.
        for choice in Self.cleanupChoices {
            cleanupAgePopup.addItem(withTitle: choice.title)
        }
        cleanupAgePopup.target = self
        cleanupAgePopup.action = #selector(cleanupCriteriaChanged)
        cleanupAgePopup.setAccessibilityLabel("Cleanup age threshold")
        cleanupPreviewButton.target = self
        cleanupPreviewButton.action = #selector(previewCleanup)
        cleanupPreviewButton.toolTip = "Show exactly how many clips and bytes this cleanup would remove"
        cleanupPreviewButton.setAccessibilityLabel("Preview the cleanup impact")
        cleanupDeleteButton.target = self
        cleanupDeleteButton.action = #selector(executeCleanup)
        cleanupDeleteButton.isEnabled = false
        cleanupDeleteButton.toolTip = "Delete the previewed clips — cannot be undone"
        cleanupDeleteButton.setAccessibilityLabel("Delete the previewed clips")
        let bulkButton = NSButton(title: "Bulk Cleanup…", target: self, action: #selector(openBulkSheet))
        bulkButton.toolTip = "Open the bulk cleanup sheet with app, type, and sensitivity filters"
        bulkButton.setAccessibilityLabel("Open the bulk cleanup sheet")
        let cleanupRow = NSStackView(views: [
            cleanupAgePopup, cleanupPreviewButton, cleanupDeleteButton, NSView(), bulkButton
        ])
        cleanupRow.orientation = .horizontal
        cleanupRow.spacing = 9
        cleanupResultLabel.font = .systemFont(ofSize: 11)
        cleanupResultLabel.textColor = .secondaryLabelColor
        cleanupResultLabel.stringValue = "Preview first — deletion cannot be undone. Pinned clips are kept unless included in Bulk Cleanup."
        let cleanupCard = card(
            title: "Cleanup",
            subtitle: "Reclaim space by deleting old clips. Every run previews the exact impact first.",
            symbol: "trash.fill",
            tint: .systemBlue,
            views: [cleanupRow, cleanupResultLabel]
        )

        stack.addArrangedSubview(overviewCard)
        stack.addArrangedSubview(blockedCard)
        stack.addArrangedSubview(maintenanceCard)
        stack.addArrangedSubview(cleanupCard)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshClicked))
        refreshButton.toolTip = "Recompute archive health and recent blocked items"
        refreshButton.setAccessibilityLabel("Refresh the dashboard")
        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(refreshButton)
        stack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: contentView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
    }

    private func card(
        title: String,
        subtitle: String,
        symbol: String,
        tint: NSColor,
        views: [NSView]
    ) -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 9
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let titleColumn = NSStackView()
        titleColumn.orientation = .vertical
        titleColumn.alignment = .leading
        titleColumn.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        titleColumn.addArrangedSubview(titleLabel)
        titleColumn.addArrangedSubview(subtitleLabel)
        heading.addArrangedSubview(icon)
        heading.addArrangedSubview(titleColumn)
        stack.addArrangedSubview(heading)
        for view in views {
            stack.addArrangedSubview(view)
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -15)
        ])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }

    private func overviewRow(_ label: String, _ value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12)
        name.textColor = .secondaryLabelColor
        name.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let amount = NSTextField(labelWithString: value)
        amount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        row.addArrangedSubview(name)
        row.addArrangedSubview(amount)
        row.addArrangedSubview(NSView())
        return row
    }

    // MARK: - Refresh (off-main health computation)

    @objc private func refreshClicked() {
        refresh()
    }

    func refresh() {
        guard !workInFlight else {
            return
        }
        workInFlight = true
        statusLabel.stringValue = "Checking archive health…"
        let archiveRoot = archiveRoot
        let reader = reader
        workQueue.async { @Sendable [weak self] in
            let health = try? ClipboardArchiveHealthReporter(archiveRoot: archiveRoot).health()
            let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            let blocked = (try? reader.recentBlockedEvents(since: since, limit: 8)) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.workInFlight = false
                    self.renderOverview(health)
                    self.renderBlocked(blocked)
                    self.statusLabel.stringValue = health == nil
                        ? "Health check failed"
                        : "Updated \(Self.timeFormatter.string(from: Date()))"
                }
            }
        }
    }

    private func renderOverview(_ health: ClipboardArchiveHealth?) {
        lastHealth = health
        overviewGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let health else {
            overviewGrid.addArrangedSubview(overviewRow("Health", "unavailable"))
            return
        }
        let rows: [(String, String)] = [
            ("Stored clips", "\(health.storedEvents)"),
            ("Blocked items (never stored)", "\(health.blockedEvents)"),
            ("Deleted (tombstoned)", "\(health.deletedEvents)"),
            ("Restricted (hidden from search)", "\(health.restrictedEvents)"),
            ("Pinned · tagged · expiring", "\(health.pinnedItems) · \(health.taggedItems) · \(health.expiringItems)"),
            ("Archive size", Self.bytes(health.archiveBytes)),
            ("Large clip bodies", "\(health.largeBodyFiles) files · \(Self.bytes(health.bodyFileBytes))"),
            ("Event files", "\(health.eventFileCount)"),
            ("Search index", "\(Self.bytes(health.indexBytes)) · schema v\(health.indexUserVersion.map(String.init) ?? "—")\(health.indexIsStale ? " · stale" : "")"),
            ("Annotations file", Self.bytes(health.annotationsBytes)),
            ("Oldest clip", health.oldestCapturedAt.map(Self.dateFormatter.string(from:)) ?? "—"),
            ("Newest clip", health.latestCapturedAt.map(Self.dateFormatter.string(from:)) ?? "—"),
            ("Files with broad permissions", "\(health.insecureFiles)"),
            ("Invalid JSON lines", "\(health.invalidJSONLines)")
        ]
        for (label, value) in rows {
            overviewGrid.addArrangedSubview(overviewRow(label, value))
        }
    }

    private func renderBlocked(_ blocked: [BlockedClipboardEvent]) {
        blockedList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lastBlockedExplanations = []
        guard !blocked.isEmpty else {
            let empty = NSTextField(labelWithString: "Nothing blocked in the last 7 days.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            blockedList.addArrangedSubview(empty)
            return
        }
        for event in blocked {
            let explanation = ClipboardBlockedEventExplainer.explanation(for: event.reason)
            lastBlockedExplanations.append(explanation)
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 1
            let headline = NSTextField(
                labelWithString: "\(event.sourceApp.name) · \(Self.dateFormatter.string(from: event.capturedAt))"
            )
            headline.font = .systemFont(ofSize: 12, weight: .medium)
            let detail = NSTextField(wrappingLabelWithString: explanation)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            row.addArrangedSubview(headline)
            row.addArrangedSubview(detail)
            blockedList.addArrangedSubview(row)
        }
    }

    // MARK: - Maintenance

    @objc private func rebuildIndexClicked() {
        guard !workInFlight else {
            return
        }
        workInFlight = true
        maintenanceReceipt.stringValue = "Rebuilding search index…"
        let index = derivedIndex
        workQueue.async { @Sendable [weak self] in
            let started = Date()
            var receipt: String
            do {
                let count = try index.rebuild()
                let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
                receipt = "Rebuilt: \(count) clips indexed in \(elapsed) s."
            } catch {
                receipt = "Rebuild failed: \(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.workInFlight = false
                    self.maintenanceReceipt.stringValue = receipt
                    self.refresh()
                }
            }
        }
    }

    @objc private func verifyIntegrityClicked() {
        guard !workInFlight else {
            return
        }
        workInFlight = true
        maintenanceReceipt.stringValue = "Verifying…"
        let index = derivedIndex
        let archiveRoot = archiveRoot
        workQueue.async { @Sendable [weak self] in
            let indexOK = index.quickCheck()
            let health = try? ClipboardArchiveHealthReporter(archiveRoot: archiveRoot).health()
            let receipt: String
            if let health {
                let indexPart = FileManager.default.fileExists(atPath: index.indexURL.path)
                    ? "Index quick_check: \(indexOK ? "ok" : "FAILED")"
                    : "Index: not built yet"
                receipt = "\(indexPart) · \(health.storedEvents) stored · "
                    + "\(health.invalidJSONLines) invalid lines · "
                    + "\(health.missingBodyFiles) missing bodies · "
                    + "\(health.insecureFiles) permission issues"
            } else {
                receipt = "Verification failed: health scan errored."
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.workInFlight = false
                    self.maintenanceReceipt.stringValue = receipt
                }
            }
        }
    }

    // MARK: - Cleanup (through the bulk engine only)

    private func cleanupCutoff() -> Date {
        let days = Self.cleanupChoices[max(0, cleanupAgePopup.indexOfSelectedItem)].days
        return Calendar.current.date(byAdding: .day, value: -days, to: Date())
            ?? Date().addingTimeInterval(TimeInterval(-days) * 86_400)
    }

    @objc private func cleanupCriteriaChanged() {
        // Any edit invalidates the preview (truthful-preview contract).
        previewedCleanupCutoffIndex = nil
        lastCleanupPreview = nil
        cleanupDeleteButton.isEnabled = false
        cleanupResultLabel.stringValue = "Criteria changed — preview again before deleting."
    }

    @objc private func previewCleanup() {
        guard !workInFlight else {
            return
        }
        workInFlight = true
        let selectedIndex = cleanupAgePopup.indexOfSelectedItem
        let criteria = ClipboardBulkCriteria(until: cleanupCutoff())
        cleanupResultLabel.stringValue = "Previewing…"
        let engine = ClipboardBulkEngine(archiveRoot: archiveRoot)
        workQueue.async { @Sendable [weak self] in
            let preview = try? engine.preview(criteria)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.workInFlight = false
                    guard let preview else {
                        self.cleanupResultLabel.stringValue = "Preview failed."
                        return
                    }
                    self.lastCleanupPreview = preview
                    self.previewedCleanupCutoffIndex = selectedIndex
                    var text = "Would delete \(preview.matchedEvents) clip\(preview.matchedEvents == 1 ? "" : "s"), reclaiming \(Self.bytes(preview.reclaimedBytes))."
                    if preview.exemptedPinnedEvents > 0 {
                        text += " \(preview.exemptedPinnedEvents) pinned clip\(preview.exemptedPinnedEvents == 1 ? "" : "s") will be kept."
                    }
                    self.cleanupResultLabel.stringValue = text
                    self.cleanupDeleteButton.isEnabled = preview.matchedEvents > 0
                }
            }
        }
    }

    @objc private func executeCleanup() {
        guard previewedCleanupCutoffIndex == cleanupAgePopup.indexOfSelectedItem,
              let preview = lastCleanupPreview else {
            cleanupResultLabel.stringValue = "Preview again before deleting."
            cleanupDeleteButton.isEnabled = false
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(preview.matchedEvents) clip\(preview.matchedEvents == 1 ? "" : "s")?"
        alert.informativeText = "Reclaims about \(Self.bytes(preview.reclaimedBytes)). This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        guard !workInFlight else {
            return
        }
        workInFlight = true
        cleanupDeleteButton.isEnabled = false
        cleanupResultLabel.stringValue = "Deleting…"
        let criteria = ClipboardBulkCriteria(until: cleanupCutoff())
        let engine = ClipboardBulkEngine(archiveRoot: archiveRoot)
        workQueue.async { @Sendable [weak self] in
            let result = try? engine.execute(criteria)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.workInFlight = false
                    self.previewedCleanupCutoffIndex = nil
                    self.lastCleanupPreview = nil
                    if let result {
                        self.cleanupResultLabel.stringValue = "Deleted \(result.matchedEvents) clip\(result.matchedEvents == 1 ? "" : "s"), reclaimed \(Self.bytes(result.reclaimedBytes))."
                        self.onArchiveMutated()
                        self.refresh()
                    } else {
                        self.cleanupResultLabel.stringValue = "Deletion failed."
                    }
                }
            }
        }
    }

    @objc private func openBulkSheet() {
        guard let window else {
            return
        }
        let controller = ClipboardBulkSheetController(
            archiveRoot: archiveRoot,
            onExecuted: { [weak self] _ in
                self?.onArchiveMutated()
                self?.refresh()
            }
        )
        bulkSheetController = controller
#if DEBUG
        if ProcessInfo.processInfo.environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN"] != nil {
            // Attached sheets cache blank bitmaps in the offscreen harness;
            // automation presents the same controller as a plain window.
            controller.sheetWindow.orderFrontRegardless()
            return
        }
#endif
        window.beginSheet(controller.sheetWindow) { [weak self] _ in
            self?.bulkSheetController = nil
        }
    }

    // MARK: - Formatting

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()
}
