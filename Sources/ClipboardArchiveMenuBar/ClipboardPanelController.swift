import ClipboardArchiveCore
import AppKit
import Foundation

@MainActor
final class ClipboardPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
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
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete Content", target: nil, action: nil)

    init(archiveRoot: URL, pasteboard: NSPasteboard, recentItemLimit: Int) {
        self.archiveRoot = archiveRoot
        self.reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        self.redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
        self.pasteboard = pasteboard
        self.recentItemLimit = recentItemLimit

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Archive"
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(recentItemLimit: Int) {
        self.recentItemLimit = recentItemLimit
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        searchField.placeholderString = "Search loaded clipboard items"
        searchField.delegate = self
        root.addArrangedSubview(searchField)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 56
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        root.addArrangedSubview(scrollView)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refresh))
        let archiveButton = NSButton(title: "Open Archive", target: self, action: #selector(openArchive))
        actions.addArrangedSubview(copyButton)
        actions.addArrangedSubview(deleteButton)
        actions.addArrangedSubview(refreshButton)
        actions.addArrangedSubview(archiveButton)
        actions.addArrangedSubview(NSView())
        actions.addArrangedSubview(statusLabel)
        root.addArrangedSubview(actions)
    }

    @objc private func refresh() {
        reload()
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
            statusLabel.stringValue = "Copy failed"
            return
        }
        let content = contents.count == 1 ? contents[0] : contents.joined(separator: "\n\n")
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        statusLabel.stringValue = contents.count == 1 ? "Copied 1 item" : "Copied \(contents.count) items"
    }

    @objc private func deleteSelected() {
        let selected = selectedEvents()
        guard !selected.isEmpty else {
            return
        }
        let alert = NSAlert()
        alert.messageText = selected.count == 1 ? "Delete Clipboard Content?" : "Delete \(selected.count) Clipboard Items?"
        alert.informativeText = "This redacts stored content, removes large body files, and purges local search rows. Timeline metadata remains."
        alert.addButton(withTitle: selected.count == 1 ? "Delete" : "Delete \(selected.count)")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            for event in selected {
                try redactor.redact(eventID: event.id)
            }
            statusLabel.stringValue = selected.count == 1 ? "Deleted 1 item" : "Deleted \(selected.count) items"
            reload()
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
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        updateStatus()
        tableView.reloadData()
        updateActionButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredEvents.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredEvents.count else {
            return nil
        }
        let event = filteredEvents[row]
        let cell = NSTableCellView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)

        let title = NSTextField(labelWithString: "\(shortDate(event.capturedAt))  \(event.sourceApp.name)  \(event.contentType.rawValue.uppercased())")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let preview = NSTextField(labelWithString: event.contentPreview)
        preview.font = event.contentType == .code ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        preview.lineBreakMode = .byTruncatingTail

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(preview)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        updateActionButtons()
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
        if selectedCount > 0 {
            statusLabel.stringValue = "\(filteredEvents.count) item(s), \(selectedCount) selected"
        } else {
            statusLabel.stringValue = "\(filteredEvents.count) item(s)"
        }
    }

    private func updateActionButtons() {
        let hasSelection = !tableView.selectedRowIndexes.isEmpty
        copyButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}
