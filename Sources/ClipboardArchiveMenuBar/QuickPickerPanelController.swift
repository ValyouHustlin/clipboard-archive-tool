import ClipboardArchiveCore
import AppKit
import Foundation

/// Borderless, nonactivating floating panel for the quick picker. The
/// borderless style mask makes AppKit refuse key status by default, so the
/// `canBecomeKey` override is load-bearing: without it the search field never
/// receives typing. The panel must never become main — the frontmost app
/// stays active throughout, which is what makes copy-back and direct paste
/// land in the right place.
final class QuickPickerPanel: NSPanel {
    var onCommandReturn: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// ⌘↩ is a key equivalent, so it never reaches the field editor's
    /// `doCommandBy` routing — intercept it here (design: commit with
    /// direct paste).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Controller for the global-shortcut quick picker (expansion contract 8).
/// The picker has ZERO pasteboard access of its own: committing routes
/// through the injected `copyToPasteboard` dependency, which wraps the app
/// delegate's shared no-re-capture copy helper.
@MainActor
final class QuickPickerPanelController: NSObject,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate,
    NSControlTextEditingDelegate {
    /// One snippet entry for the picker's top section (contract 5).
    /// `hasLiveOccurrence` is resolved at LOAD for enablement; the commit
    /// re-resolves at commit time (newest live occurrence wins).
    struct SnippetItem {
        var contentHash: String
        var title: String
        var hasLiveOccurrence: Bool
    }

    /// Rows the table renders. Snippets (with a section header) appear only
    /// while the query is empty and snippets exist; typing filters events
    /// only.
    private enum PickerRow {
        case header(String)
        case snippet(SnippetItem)
        case event(StoredClipboardEvent)
    }

    struct Dependencies {
        /// Loads the picker's event list (app delegate cache; warm opens are O(1)).
        var loadEvents: () -> [StoredClipboardEvent]
        /// Loads snippet entries (cached beside the event cache; invalidated
        /// on every archive/annotations mutation).
        var loadSnippets: () -> [SnippetItem]
        /// Shared no-re-capture copy path. Returns the copied content on
        /// success, nil on failure (event body unreadable).
        var copyToPasteboard: (StoredClipboardEvent) -> String?
        /// Commit-time snippet resolution: newest live occurrence →
        /// content → shared no-re-capture copy path. Returns the copied
        /// content, or nil when no live occurrence remains.
        var commitSnippet: (SnippetItem) -> String?
        /// Whether direct paste may run right now (setting enabled AND
        /// Accessibility trusted — re-checked at every use).
        var directPasteAllowed: () -> Bool
        /// Posts ⌘V into the frontmost app. Only invoked after
        /// `directPasteAllowed()` returns true.
        var performDirectPaste: () -> Void
    }

    private let dependencies: Dependencies
    private let panel: QuickPickerPanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let hintLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    private var events: [StoredClipboardEvent] = []
    private var filteredEvents: [StoredClipboardEvent] = []
    private var snippets: [SnippetItem] = []
    private var rows: [PickerRow] = []
    /// Guards the resign-key dismissal path so the deliberate teardown during
    /// a commit is not treated as a click-away dismissal.
    private var isCommitting = false
    // nonisolated(unsafe): only ever touched on the main actor; the marker
    // exists so the nonisolated deinit can release it (Swift 6 rule).
    private nonisolated(unsafe) var resignKeyObserver: NSObjectProtocol?

#if DEBUG
    private(set) var automationLastCommittedContent: String?
    private(set) var automationLastSelectedPreview: String = ""
    private(set) var automationLastOpenElapsedMilliseconds: Double = 0
#endif

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        panel = QuickPickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.onCommandReturn = { [weak self] in
            self?.commit(directPaste: true)
        }
        buildUI()

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCommitting else {
                    return
                }
                self.dismiss()
            }
        }
    }

    deinit {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
    }

    // MARK: - Presentation

    var isVisible: Bool {
        panel.isVisible
    }

    /// The hotkey entry point: open when closed, close when open.
    func toggle() {
        if panel.isVisible {
            dismiss()
        } else {
            present()
        }
    }

    func present() {
        let start = DispatchTime.now()
        events = dependencies.loadEvents()
        snippets = dependencies.loadSnippets()
        searchField.stringValue = ""
        applyFilter()
        statusLabel.stringValue = ""
        updateHint()
        positionPanel()
        // Deliberately no NSApp.activate: the nonactivating panel takes key
        // status while the frontmost app stays active.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
#if DEBUG
        automationLastOpenElapsedMilliseconds = elapsed
#endif
    }

    func dismiss() {
        panel.orderOut(nil)
    }

    private func positionPanel() {
        guard let screen = NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        // Center the panel on the boundary of the screen's top third.
        let y = visible.minY + visible.height * 2 / 3 - size.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, y)))
    }

    private func updateHint() {
        hintLabel.stringValue = dependencies.directPasteAllowed()
            ? "↩ copy   ⌘↩ paste   esc close"
            : "↩ copy   esc close"
    }

    // MARK: - Filtering and selection

    private func applyFilter() {
        filteredEvents = ClipboardQuickPickerFilter.filter(
            events: events,
            query: searchField.stringValue
        )
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var built: [PickerRow] = []
        // Snippets: top section, only when the query is empty and snippets
        // exist (typing means "search my recent clips").
        if query.isEmpty, !snippets.isEmpty {
            built.append(.header("Snippets"))
            built.append(contentsOf: snippets.map { .snippet($0) })
            built.append(.header("Recent Clips"))
        }
        built.append(contentsOf: filteredEvents.map { .event($0) })
        rows = built
        tableView.reloadData()
        selectFirstSelectableRow()
    }

    private func isSelectable(_ row: Int) -> Bool {
        guard row >= 0, row < rows.count else {
            return false
        }
        switch rows[row] {
        case .header:
            return false
        case let .snippet(snippet):
            return snippet.hasLiveOccurrence
        case .event:
            return true
        }
    }

    private func selectFirstSelectableRow() {
        guard let first = rows.indices.first(where: { isSelectable($0) }) else {
            tableView.deselectAll(nil)
            rememberSelection()
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        tableView.scrollRowToVisible(first)
        rememberSelection()
    }

    /// Moves the selection to the next selectable row in `delta`'s
    /// direction, skipping headers and disabled snippet rows.
    private func moveSelection(by delta: Int) {
        guard rows.contains(where: { _ in true }) else {
            return
        }
        let direction = delta >= 0 ? 1 : -1
        var candidate = tableView.selectedRow
        if candidate < 0 {
            selectFirstSelectableRow()
            return
        }
        repeat {
            candidate += direction
        } while candidate >= 0 && candidate < rows.count && !isSelectable(candidate)
        guard candidate >= 0, candidate < rows.count else {
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: candidate), byExtendingSelection: false)
        tableView.scrollRowToVisible(candidate)
        rememberSelection()
    }

    private var selectedRow: PickerRow? {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else {
            return nil
        }
        return rows[row]
    }

    private var selectedEvent: StoredClipboardEvent? {
        if case let .event(event)? = selectedRow {
            return event
        }
        return nil
    }

    private func rememberSelection() {
#if DEBUG
        switch selectedRow {
        case let .event(event):
            automationLastSelectedPreview = event.contentPreview
        case let .snippet(snippet):
            automationLastSelectedPreview = snippet.title
        default:
            automationLastSelectedPreview = ""
        }
#endif
    }

    // MARK: - Commit

    /// Commit sequence (design order is load-bearing): mark committing →
    /// copy BEFORE teardown → dismiss → optionally schedule direct paste
    /// 80 ms later so the panel has resigned key and ⌘V lands in the
    /// user's app. On copy failure the panel stays open with inline status.
    ///
    /// Snippet rows resolve AT COMMIT TIME (newest live occurrence →
    /// content → shared no-re-capture copy path).
    private func commit(directPaste: Bool) {
        let content: String?
        switch selectedRow {
        case let .event(event):
            isCommitting = true
            content = dependencies.copyToPasteboard(event)
            if content == nil {
                isCommitting = false
                statusLabel.stringValue = "Could not copy that item"
                return
            }
        case let .snippet(snippet):
            isCommitting = true
            content = dependencies.commitSnippet(snippet)
            if content == nil {
                isCommitting = false
                statusLabel.stringValue = "That snippet has no copies left in the archive"
                return
            }
        default:
            statusLabel.stringValue = "Nothing to copy"
            return
        }
#if DEBUG
        automationLastCommittedContent = content
#endif
        dismiss()
        if directPaste, dependencies.directPasteAllowed() {
            let paste = dependencies.performDirectPaste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                paste()
            }
        }
        isCommitting = false
    }

    // MARK: - Keyboard routing

    /// All typing goes to the window's field editor; navigation and commit
    /// keys are intercepted here before the field editor consumes them.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit(directPaste: false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.insertTab(_:)):
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    @objc private func rowDoubleClicked() {
        commit(directPaste: false)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        isSelectable(row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else {
            return 44
        }
        if case .header = rows[row] {
            return 22
        }
        return 44
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < rows.count else {
            return nil
        }
        switch rows[row] {
        case let .header(title):
            return headerCell(title: title)
        case let .snippet(snippet):
            return snippetCell(snippet: snippet)
        case let .event(event):
            return eventCell(event: event)
        }
    }

    private func headerCell(title: String) -> NSView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2)
        ])
        return cell
    }

    private func snippetCell(snippet: SnippetItem) -> NSView {
        let cell = NSTableCellView()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "text.badge.star",
            accessibilityDescription: "Snippet"
        )
        icon.contentTintColor = snippet.hasLiveOccurrence ? .systemOrange : .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: snippet.title)
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = snippet.hasLiveOccurrence ? .labelColor : .tertiaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        let metadata = NSTextField(
            labelWithString: snippet.hasLiveOccurrence
                ? "Snippet"
                : "Snippet · no copies left in the archive"
        )
        metadata.font = .systemFont(ofSize: 10, weight: .medium)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        metadata.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(titleField)
        cell.addSubview(metadata)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            titleField.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            metadata.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2)
        ])
        return cell
    }

    private func eventCell(event: StoredClipboardEvent) -> NSView {
        let cell = NSTableCellView()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName(for: event.contentType),
            accessibilityDescription: event.contentType.rawValue
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSTextField(labelWithString: singleLine(event.contentPreview))
        preview.font = event.contentType == .code
            ? .monospacedSystemFont(ofSize: 12, weight: .regular)
            : .systemFont(ofSize: 12)
        preview.lineBreakMode = .byTruncatingTail
        preview.translatesAutoresizingMaskIntoConstraints = false

        let metadata = NSTextField(
            labelWithString: "\(event.sourceApp.name)  ·  \(relativeDate(event.capturedAt))"
        )
        metadata.font = .systemFont(ofSize: 10, weight: .medium)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        metadata.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(icon)
        cell.addSubview(preview)
        cell.addSubview(metadata)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            preview.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            metadata.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 2)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        rememberSelection()
    }

    // MARK: - UI construction

    private func buildUI() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        searchField.placeholderString = "Search recent clips"
        searchField.font = .systemFont(ofSize: 17)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.setAccessibilityLabel("Quick picker search")

        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.setAccessibilityLabel("Quick picker results")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quickpicker"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        tableView.frame = scroll.contentView.bounds
        tableView.autoresizingMask = [.width]
        scroll.documentView = tableView

        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.alignment = .right

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.addArrangedSubview(hintLabel)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(statusLabel)

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(searchField)
        stack.addArrangedSubview(separator)
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(footer)

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        panel.contentView = background
    }

    /// Icon mapping lives on `ClipboardContentType.systemSymbolName` in
    /// Core (Slice 6) — one shared source for the panel and the picker.
    private func symbolName(for contentType: ClipboardContentType) -> String {
        contentType.systemSymbolName
    }

    private func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    private func relativeDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

#if DEBUG
    // MARK: - Automation harness (isolated /tmp roots only; see main.swift)

    var automationFilteredCount: Int {
        filteredEvents.count
    }

    func performAutomationQuery(_ query: String) {
        searchField.stringValue = query
        applyFilter()
    }

    /// Routes a named gesture through the SAME handlers the field editor
    /// routing uses, so automation exercises production key paths.
    func performAutomationGesture(_ gesture: String) {
        switch gesture.trimmingCharacters(in: .whitespaces).lowercased() {
        case "down":
            moveSelection(by: 1)
        case "up":
            moveSelection(by: -1)
        case "return":
            commit(directPaste: false)
        case "escape":
            dismiss()
        default:
            break
        }
    }

    func writeSnapshot(to url: URL) throws {
        guard let view = panel.contentView else {
            return
        }
        view.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
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
}
