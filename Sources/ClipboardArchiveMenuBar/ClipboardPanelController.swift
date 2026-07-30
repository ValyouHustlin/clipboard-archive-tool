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
    private var historyWindow: ClipboardHistoryWindow
    private var contentTypeFilter: ClipboardContentType?

    private let searchField = NSSearchField()
    private let historySubtitle = NSTextField(labelWithString: "")
    private let typeFilter = NSSegmentedControl()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailTitle = NSTextField(labelWithString: "Select an item")
    private let detailMetadata = NSTextField(labelWithString: "Choose a clip to preview its full text.")
    private let detailTextView = NSTextView()
    private let detailCapturedValue = NSTextField(labelWithString: "—")
    private let detailFormatValue = NSTextField(labelWithString: "—")
    private let detailSizeValue = NSTextField(labelWithString: "—")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var detailCardHeightConstraint: NSLayoutConstraint?

    init(
        archiveRoot: URL,
        pasteboard: NSPasteboard,
        recentItemLimit: Int,
        historyWindow: ClipboardHistoryWindow
    ) {
        self.archiveRoot = archiveRoot
        self.reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        self.redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
        self.pasteboard = pasteboard
        self.recentItemLimit = recentItemLimit
        self.historyWindow = historyWindow

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard History"
        window.minSize = NSSize(width: 720, height: 440)
        window.center()
        window.setFrameAutosaveName("ClipboardHistoryWindowV2")
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(
        recentItemLimit: Int,
        historyWindow: ClipboardHistoryWindow,
        focusSearch: Bool = false,
        activate: Bool = true
    ) {
        self.recentItemLimit = recentItemLimit
        self.historyWindow = historyWindow
        reload()
        if activate {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderFrontRegardless()
        }
        DispatchQueue.main.async { [weak self] in
            self?.resizeTableToViewport()
        }
        if focusSearch, activate {
            window?.makeFirstResponder(searchField)
        }
    }

    private func resizeTableToViewport() {
        guard let scrollView = tableView.enclosingScrollView,
              let column = tableView.tableColumns.first else {
            return
        }
        scrollView.layoutSubtreeIfNeeded()
        let availableWidth = max(1, scrollView.contentSize.width)
        tableView.setFrameSize(
            NSSize(width: availableWidth, height: tableView.frame.height)
        )
        column.width = availableWidth
        tableView.needsDisplay = true
    }

#if DEBUG
    func writeSnapshot(to url: URL) throws {
        guard let view = window?.contentView else {
            return
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

    func performAutomationSearch(_ query: String) {
        searchField.stringValue = query
        applyFilter()
    }

    func performAutomationTypeFilter(_ filter: String) {
        let segment = ["all", "text", "links", "code"]
            .firstIndex(of: filter.lowercased()) ?? 0
        typeFilter.selectedSegment = segment
        typeFilter.performClick(nil)
    }
#endif

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let listPane = NSVisualEffectView()
        listPane.material = .sidebar
        listPane.blendingMode = .behindWindow
        listPane.state = .active
        listPane.translatesAutoresizingMaskIntoConstraints = false

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.edgeInsets = NSEdgeInsets(top: 18, left: 14, bottom: 12, right: 14)
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listPane.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: listPane.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: listPane.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: listPane.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: listPane.bottomAnchor),
            listPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 290)
        ])
        let preferredSidebarWidth = listPane.widthAnchor.constraint(equalToConstant: 340)
        preferredSidebarWidth.priority = .defaultHigh
        preferredSidebarWidth.isActive = true

        let listHeading = NSStackView()
        listHeading.orientation = .vertical
        listHeading.alignment = .leading
        listHeading.spacing = 2
        let title = NSTextField(labelWithString: "History")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        historySubtitle.font = .systemFont(ofSize: 11)
        historySubtitle.textColor = .secondaryLabelColor
        listHeading.addArrangedSubview(title)
        listHeading.addArrangedSubview(historySubtitle)
        listStack.addArrangedSubview(listHeading)
        listHeading.widthAnchor.constraint(
            equalTo: listStack.widthAnchor,
            constant: -28
        ).isActive = true

        searchField.placeholderString = "Search clips"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        listStack.addArrangedSubview(searchField)
        searchField.widthAnchor.constraint(
            equalTo: listStack.widthAnchor,
            constant: -28
        ).isActive = true

        typeFilter.segmentCount = 4
        for (segment, label) in ["All", "Text", "Links", "Code"].enumerated() {
            typeFilter.setLabel(label, forSegment: segment)
        }
        typeFilter.segmentStyle = .rounded
        typeFilter.trackingMode = .selectOne
        typeFilter.selectedSegment = 0
        typeFilter.target = self
        typeFilter.action = #selector(typeFilterChanged)
        typeFilter.setAccessibilityLabel("Filter history by content type")
        listStack.addArrangedSubview(typeFilter)
        typeFilter.widthAnchor.constraint(
            equalTo: listStack.widthAnchor,
            constant: -28
        ).isActive = true

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listStack.addArrangedSubview(listScroll)
        listScroll.widthAnchor.constraint(
            equalTo: listStack.widthAnchor,
            constant: -28
        ).isActive = true

        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 58
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(copySelected)
        let contextMenu = NSMenu()
        let copyItem = NSMenuItem(
            title: "Copy Selected",
            action: #selector(copySelected),
            keyEquivalent: ""
        )
        copyItem.target = self
        contextMenu.addItem(copyItem)
        let deleteItem = NSMenuItem(
            title: "Delete Selected…",
            action: #selector(deleteSelected),
            keyEquivalent: ""
        )
        deleteItem.target = self
        contextMenu.addItem(deleteItem)
        tableView.menu = contextMenu
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clipboard"))
        column.resizingMask = .autoresizingMask
        column.width = 312
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.frame = listScroll.contentView.bounds
        tableView.autoresizingMask = [.width]
        listScroll.documentView = tableView

        let listFooter = NSStackView()
        listFooter.orientation = .horizontal
        listFooter.alignment = .centerY
        listFooter.spacing = 8
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        let refreshButton = symbolButton(
            symbol: "arrow.clockwise",
            accessibilityLabel: "Refresh history",
            action: #selector(refresh)
        )
        listFooter.addArrangedSubview(statusLabel)
        listFooter.addArrangedSubview(NSView())
        listFooter.addArrangedSubview(refreshButton)
        listStack.addArrangedSubview(listFooter)
        listFooter.widthAnchor.constraint(
            equalTo: listStack.widthAnchor,
            constant: -28
        ).isActive = true

        let detailPane = NSView()
        detailPane.translatesAutoresizingMaskIntoConstraints = false

        let detailStack = NSStackView()
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 14
        detailStack.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 20, right: 26)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailPane.addSubview(detailStack)
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailPane.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailPane.bottomAnchor),
            detailPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 400)
        ])

        let detailHeader = NSStackView()
        detailHeader.orientation = .horizontal
        detailHeader.alignment = .top
        detailHeader.spacing = 14

        let detailHeadings = NSStackView()
        detailHeadings.orientation = .vertical
        detailHeadings.alignment = .leading
        detailHeadings.spacing = 4
        detailTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        detailTitle.lineBreakMode = .byTruncatingTail
        detailMetadata.font = .systemFont(ofSize: 11)
        detailMetadata.textColor = .secondaryLabelColor
        detailMetadata.lineBreakMode = .byTruncatingMiddle
        detailHeadings.addArrangedSubview(detailTitle)
        detailHeadings.addArrangedSubview(detailMetadata)

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        copyButton.bezelStyle = .texturedRounded
        copyButton.title = ""
        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy selected clips"
        )
        copyButton.toolTip = "Copy selected clips"
        copyButton.setAccessibilityLabel("Copy selected clips")
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.bezelStyle = .texturedRounded
        deleteButton.title = ""
        deleteButton.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "Delete selected clips"
        )
        deleteButton.toolTip = "Delete selected clips"
        deleteButton.setAccessibilityLabel("Delete selected clips")

        let revealButton = symbolButton(
            symbol: "folder",
            accessibilityLabel: "Show archive in Finder",
            action: #selector(openArchive)
        )

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        actions.addArrangedSubview(revealButton)
        actions.addArrangedSubview(deleteButton)
        actions.addArrangedSubview(copyButton)

        detailHeader.addArrangedSubview(detailHeadings)
        detailHeader.addArrangedSubview(NSView())
        detailHeader.addArrangedSubview(actions)
        detailStack.addArrangedSubview(detailHeader)
        detailHeader.widthAnchor.constraint(
            equalTo: detailStack.widthAnchor,
            constant: -52
        ).isActive = true
        detailHeadings.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailSeparator = separatorView()
        detailStack.addArrangedSubview(detailSeparator)
        detailSeparator.widthAnchor.constraint(
            equalTo: detailStack.widthAnchor,
            constant: -52
        ).isActive = true

        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .noBorder
        detailScroll.drawsBackground = false
        detailTextView.isEditable = false
        detailTextView.isSelectable = true
        detailTextView.drawsBackground = false
        detailTextView.textContainerInset = NSSize(width: 0, height: 8)
        detailTextView.font = .systemFont(ofSize: 15)
        detailTextView.string = ""
        detailTextView.isVerticallyResizable = true
        detailTextView.isHorizontallyResizable = false
        detailTextView.autoresizingMask = [.width]
        detailTextView.textContainer?.widthTracksTextView = true
        detailTextView.frame = detailScroll.contentView.bounds
        detailScroll.documentView = detailTextView

        let contentCard = NSVisualEffectView()
        contentCard.material = .contentBackground
        contentCard.blendingMode = .withinWindow
        contentCard.state = .active
        contentCard.wantsLayer = true
        contentCard.layer?.cornerRadius = 10
        contentCard.layer?.borderWidth = 1
        contentCard.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        contentCard.addSubview(detailScroll)
        let detailCardHeight = contentCard.heightAnchor.constraint(equalToConstant: 150)
        detailCardHeightConstraint = detailCardHeight
        NSLayoutConstraint.activate([
            detailScroll.leadingAnchor.constraint(equalTo: contentCard.leadingAnchor, constant: 18),
            detailScroll.trailingAnchor.constraint(equalTo: contentCard.trailingAnchor, constant: -18),
            detailScroll.topAnchor.constraint(equalTo: contentCard.topAnchor, constant: 12),
            detailScroll.bottomAnchor.constraint(equalTo: contentCard.bottomAnchor, constant: -12),
            detailCardHeight
        ])
        detailStack.addArrangedSubview(contentCard)
        contentCard.widthAnchor.constraint(
            equalTo: detailStack.widthAnchor,
            constant: -52
        ).isActive = true

        let detailsTitle = NSTextField(labelWithString: "Details")
        detailsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        detailsTitle.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(detailsTitle)

        let details = NSStackView()
        details.orientation = .horizontal
        details.distribution = .fillEqually
        details.alignment = .top
        details.spacing = 18
        details.addArrangedSubview(detailFact(title: "Copied", value: detailCapturedValue))
        details.addArrangedSubview(detailFact(title: "Format", value: detailFormatValue))
        details.addArrangedSubview(detailFact(title: "Size", value: detailSizeValue))
        detailStack.addArrangedSubview(details)
        details.widthAnchor.constraint(
            equalTo: detailStack.widthAnchor,
            constant: -52
        ).isActive = true

        detailStack.addArrangedSubview(NSView())
        let localNote = NSStackView()
        localNote.orientation = .horizontal
        localNote.alignment = .centerY
        localNote.spacing = 6
        let lock = NSImageView()
        lock.image = NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: "Stored locally"
        )
        lock.contentTintColor = .tertiaryLabelColor
        lock.widthAnchor.constraint(equalToConstant: 13).isActive = true
        lock.heightAnchor.constraint(equalToConstant: 13).isActive = true
        let localText = NSTextField(labelWithString: "Stored locally on this Mac")
        localText.font = .systemFont(ofSize: 11)
        localText.textColor = .tertiaryLabelColor
        localNote.addArrangedSubview(lock)
        localNote.addArrangedSubview(localText)
        localNote.addArrangedSubview(NSView())
        detailStack.addArrangedSubview(localNote)
        localNote.widthAnchor.constraint(
            equalTo: detailStack.widthAnchor,
            constant: -52
        ).isActive = true

        splitView.addArrangedSubview(listPane)
        splitView.addArrangedSubview(detailPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    }

    private func detailFact(title: String, value: NSTextField) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        titleLabel.textColor = .tertiaryLabelColor
        value.font = .systemFont(ofSize: 12, weight: .medium)
        value.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(value)
        return stack
    }

    private func separatorView() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
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

    @objc private func typeFilterChanged() {
        switch typeFilter.selectedSegment {
        case 1:
            contentTypeFilter = .text
        case 2:
            contentTypeFilter = .url
        case 3:
            contentTypeFilter = .code
        default:
            contentTypeFilter = nil
        }
        applyFilter()
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
        historySubtitle.stringValue = "\(historyWindow.displayName) · local to this Mac"
        let since = Calendar.current.date(
            byAdding: .day,
            value: -historyWindow.dayCount,
            to: Date()
        ) ?? Date()
        events = (try? reader.recentItems(since: since, limit: recentItemLimit)) ?? []
        applyFilter()
    }

    private func applyFilter() {
        let previousID = selectedEvents().first?.id
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        filteredEvents = events.filter { event in
            let matchesType = contentTypeFilter.map { event.contentType == $0 } ?? true
            let matchesQuery = query.isEmpty || [
                event.contentPreview,
                event.sourceApp.name,
                event.contentType.rawValue
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
            return matchesType && matchesQuery
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

        let metadata = NSTextField(
            labelWithString: "\(event.sourceApp.name)  ·  \(relativeDate(event.capturedAt))"
        )
        metadata.font = .systemFont(ofSize: 11, weight: .medium)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        metadata.alignment = .left

        let preview = NSTextField(labelWithString: singleLine(event.contentPreview))
        preview.font = event.contentType == .code
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 13)
        preview.lineBreakMode = .byTruncatingTail
        preview.alignment = .left

        metadata.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(preview)
        cell.addSubview(metadata)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            preview.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            preview.topAnchor.constraint(equalTo: cell.topAnchor, constant: 11),
            metadata.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 4)
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
        let isFiltered = !searchField.stringValue.isEmpty || contentTypeFilter != nil
        let base = !isFiltered
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
        detailCapturedValue.stringValue = "—"
        detailFormatValue.stringValue = "—"
        detailSizeValue.stringValue = "—"
        detailCardHeightConstraint?.constant = 150

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
        detailMetadata.stringValue = "Copied \(relativeDate(event.capturedAt))"
        detailCapturedValue.stringValue = fullDate(event.capturedAt)
        detailFormatValue.stringValue = event.contentType.rawValue.capitalized
        detailSizeValue.stringValue = ByteCountFormatter.string(
            fromByteCount: Int64(event.byteCount),
            countStyle: .file
        )
        detailCardHeightConstraint?.constant = preferredDetailCardHeight(for: event)
        detailTextView.font = event.contentType == .code
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 15)
        detailTextView.string = (try? reader.content(for: event)) ?? event.contentPreview
    }

    private func preferredDetailCardHeight(for event: StoredClipboardEvent) -> CGFloat {
        let wrappedLineEstimate = Int(ceil(Double(event.characterCount) / 64.0))
        let visibleLines = max(event.lineCount, wrappedLineEstimate)
        return min(220, max(112, CGFloat(68 + min(visibleLines, 7) * 22)))
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
