import ClipboardArchiveCore
import AppKit
import Foundation

@MainActor
final class ClipboardPanelController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate {
    private let archiveRoot: URL
    private let reader: ClipboardArchiveReader
    private let redactor: ClipboardArchiveRedactor
    private let pasteboard: NSPasteboard
    private var events: [StoredClipboardEvent] = []
    private var filteredEvents: [StoredClipboardEvent] = []
    private var recentItemLimit: Int

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailTitle = NSTextField(labelWithString: "Select an item")
    private let detailMetadata = NSTextField(labelWithString: "Choose a clip to preview its full text.")
    private let detailTextView = NSTextView()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    init(archiveRoot: URL, pasteboard: NSPasteboard, recentItemLimit: Int) {
        self.archiveRoot = archiveRoot
        self.reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        self.redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
        self.pasteboard = pasteboard
        self.recentItemLimit = recentItemLimit

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard History"
        window.minSize = NSSize(width: 760, height: 480)
        window.setFrameAutosaveName("ClipboardHistoryWindow")
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(recentItemLimit: Int, focusSearch: Bool = false) {
        self.recentItemLimit = recentItemLimit
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if focusSearch {
            window?.makeFirstResponder(searchField)
        }
    }

#if DEBUG
    func writeSnapshot(to url: URL) throws {
        guard let view = window?.contentView else {
            return
        }
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

    func performAutomationSearch(_ query: String) {
        searchField.stringValue = query
        applyFilter()
    }
#endif

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        let headings = NSStackView()
        headings.orientation = .vertical
        headings.spacing = 2
        let title = NSTextField(labelWithString: "Clipboard History")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Your last 7 days, stored locally on this Mac")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        headings.addArrangedSubview(title)
        headings.addArrangedSubview(subtitle)

        searchField.placeholderString = "Search recent clips"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        header.addArrangedSubview(headings)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(searchField)
        root.addArrangedSubview(header)

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let listPane = NSView()
        listPane.translatesAutoresizingMaskIntoConstraints = false
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(listScroll)
        NSLayoutConstraint.activate([
            listScroll.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listScroll.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            listScroll.topAnchor.constraint(equalTo: listPane.topAnchor),
            listScroll.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 350)
        ])

        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 70
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(copySelected)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.frame = listScroll.contentView.bounds
        tableView.autoresizingMask = [.width]
        listScroll.documentView = tableView

        let detailPane = NSVisualEffectView()
        detailPane.material = .contentBackground
        detailPane.blendingMode = .withinWindow
        detailPane.state = .active
        detailPane.translatesAutoresizingMaskIntoConstraints = false

        let detailStack = NSStackView()
        detailStack.orientation = .vertical
        detailStack.spacing = 12
        detailStack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailPane.addSubview(detailStack)
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailPane.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor),
            detailPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        detailTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailMetadata.font = .systemFont(ofSize: 11)
        detailMetadata.textColor = .secondaryLabelColor
        detailMetadata.lineBreakMode = .byTruncatingMiddle
        detailStack.addArrangedSubview(detailTitle)
        detailStack.addArrangedSubview(detailMetadata)

        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .noBorder
        detailScroll.drawsBackground = false
        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.drawsBackground = false
        detailTextView.textContainerInset = NSSize(width: 4, height: 8)
        detailTextView.font = .systemFont(ofSize: 14)
        detailTextView.string = ""
        detailTextView.autoresizingMask = [.width]
        detailScroll.documentView = detailTextView
        detailStack.addArrangedSubview(detailScroll)
        detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.keyEquivalent = "\r"
        copyButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .rounded

        let revealButton = NSButton(
            title: "Show Archive",
            target: self,
            action: #selector(openArchive)
        )
        revealButton.bezelStyle = .rounded
        actions.addArrangedSubview(copyButton)
        actions.addArrangedSubview(deleteButton)
        actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(revealButton)
        detailStack.addArrangedSubview(actions)

        splitView.addArrangedSubview(listPane)
        splitView.addArrangedSubview(detailPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        root.addArrangedSubview(splitView)
        splitView.widthAnchor.constraint(
            equalTo: contentView.widthAnchor,
            constant: -36
        ).isActive = true
        splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 390).isActive = true

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let refreshButton = symbolButton(
            symbol: "arrow.clockwise",
            accessibilityLabel: "Refresh history",
            action: #selector(refresh)
        )
        footer.addArrangedSubview(statusLabel)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(refreshButton)
        root.addArrangedSubview(footer)
    }

    private func symbolButton(
        symbol: String,
        accessibilityLabel: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: accessibilityLabel
        )
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    @objc private func refresh() {
        reload()
        statusLabel.stringValue = "History refreshed"
    }

    @objc private func openArchive() {
        NSWorkspace.shared.open(archiveRoot)
    }

    @objc private func copySelected() {
        let selected = selectedEvents()
        guard !selected.isEmpty else {
            return
        }
        let contents = selected.compactMap { try? reader.content(for: $0) }
        guard !contents.isEmpty else {
            statusLabel.stringValue = "Could not read the selected item"
            return
        }
        let content = contents.count == 1 ? contents[0] : contents.joined(separator: "\n\n")
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        statusLabel.stringValue = contents.count == 1 ? "Copied to clipboard" : "Copied \(contents.count) items"
    }

    @objc private func deleteSelected() {
        let selected = selectedEvents()
        guard !selected.isEmpty else {
            return
        }
        let alert = NSAlert()
        alert.messageText = selected.count == 1 ? "Delete this clip?" : "Delete \(selected.count) clips?"
        alert.informativeText = "Stored content will be redacted and removed from local search. Timeline metadata remains."
        alert.addButton(withTitle: selected.count == 1 ? "Delete Clip" : "Delete Clips")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            for event in selected {
                try redactor.redact(eventID: event.id)
            }
            reload()
            statusLabel.stringValue = selected.count == 1 ? "Clip deleted" : "\(selected.count) clips deleted"
        } catch {
            statusLabel.stringValue = "Delete failed"
        }
    }

    private func reload() {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        events = (try? reader.recentItems(since: since, limit: recentItemLimit)) ?? []
        applyFilter()
    }

    private func applyFilter() {
        let previousID = selectedEvents().first?.id
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if query.isEmpty {
            filteredEvents = events
        } else {
            filteredEvents = events.filter { event in
                [event.contentPreview, event.sourceApp.name, event.contentType.rawValue]
                    .joined(separator: " ")
                    .lowercased()
                    .contains(query)
            }
        }
        tableView.reloadData()
        if let previousID,
           let row = filteredEvents.firstIndex(where: { $0.id == previousID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !filteredEvents.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateStatus()
        updateDetail()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEvents.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < filteredEvents.count else {
            return nil
        }
        let event = filteredEvents[row]
        let cell = NSTableCellView()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName(for: event.contentType),
            accessibilityDescription: event.contentType.rawValue
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.spacing = 5
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let metadata = NSTextField(
            labelWithString: "\(event.sourceApp.name)  ·  \(relativeDate(event.capturedAt))"
        )
        metadata.font = .systemFont(ofSize: 11, weight: .medium)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail

        let preview = NSTextField(labelWithString: singleLine(event.contentPreview))
        preview.font = event.contentType == .code
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 13)
        preview.lineBreakMode = .byTruncatingTail

        textStack.addArrangedSubview(metadata)
        textStack.addArrangedSubview(preview)
        cell.addSubview(icon)
        cell.addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        updateDetail()
    }

    private func selectedEvents() -> [StoredClipboardEvent] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < filteredEvents.count else {
                return nil
            }
            return filteredEvents[row]
        }
    }

    private func updateStatus() {
        let selectedCount = tableView.selectedRowIndexes.count
        let total = filteredEvents.count
        let base = searchField.stringValue.isEmpty
            ? "\(total) clip\(total == 1 ? "" : "s")"
            : "\(total) match\(total == 1 ? "" : "es")"
        statusLabel.stringValue = selectedCount > 1
            ? "\(base) · \(selectedCount) selected"
            : base
    }

    private func updateDetail() {
        let selected = selectedEvents()
        copyButton.isEnabled = !selected.isEmpty
        deleteButton.isEnabled = !selected.isEmpty

        guard selected.count == 1, let event = selected.first else {
            if selected.count > 1 {
                detailTitle.stringValue = "\(selected.count) clips selected"
                detailMetadata.stringValue = "Copy combines them with a blank line between each clip."
            } else if events.isEmpty {
                detailTitle.stringValue = "No clips yet"
                detailMetadata.stringValue = "Copy text in any app and it will appear here."
            } else {
                detailTitle.stringValue = "No matching clips"
                detailMetadata.stringValue = "Try a different search."
            }
            detailTextView.string = ""
            return
        }

        detailTitle.stringValue = event.sourceApp.name
        detailMetadata.stringValue = [
            fullDate(event.capturedAt),
            event.contentType.rawValue.capitalized,
            ByteCountFormatter.string(fromByteCount: Int64(event.byteCount), countStyle: .file)
        ].joined(separator: "  ·  ")
        detailTextView.font = event.contentType == .code
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 14)
        detailTextView.string = (try? reader.content(for: event)) ?? event.contentPreview
    }

    private func symbolName(for contentType: ClipboardContentType) -> String {
        switch contentType {
        case .url:
            return "link"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .blocked:
            return "hand.raised.fill"
        case .text:
            return "doc.text"
        }
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

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
