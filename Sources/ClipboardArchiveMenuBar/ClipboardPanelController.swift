import ClipboardArchiveCore
import AppKit
import Foundation

/// Table subclass so a plain Return keypress in the results list commits a
/// copy through the shared no-re-capture path (keyboard-first contract;
/// works in both scopes).
final class HistoryResultsTableView: NSTableView {
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let onReturnKey {
            onReturnKey()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class ClipboardPanelController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate {
    /// Which data source drives the results list. `.thisWindow` is the
    /// original in-memory recent-items path and its behavior is unchanged;
    /// `.allHistory` reads the derived FTS index only (contract 3 — never
    /// NDJSON scans on the UI thread).
    private enum HistoryScope {
        case thisWindow
        case allHistory
    }

    /// State machine for the all-history scope (design: full-archive UI
    /// search). `browse` and `results` both carry rows; the split keeps the
    /// status line honest about whether a query is active.
    private enum AllHistoryState {
        case browse([ClipboardIndexSearchResult])
        case searching
        case results([ClipboardIndexSearchResult])
        case empty
        case error(String)
        case preparingIndex
    }

    private let archiveRoot: URL
    private let reader: ClipboardArchiveReader
    private let redactor: ClipboardArchiveRedactor
    private let derivedIndex: ClipboardDerivedIndex
    /// Shared copy-back path owned by the app delegate
    /// (`copyToPasteboardWithoutRecapture` in main.swift). It sets the
    /// pasteboard AND updates the capture dedup state so a copy from this
    /// window is not re-captured as a new event. The panel must never write
    /// to the pasteboard directly, and the future quick picker must be wired
    /// through the same closure.
    private let copyToPasteboard: (String) -> Void
    private var events: [StoredClipboardEvent] = []
    private var filteredEvents: [StoredClipboardEvent] = []
    private var recentItemLimit: Int
    private var historyWindow: ClipboardHistoryWindow
    private var contentTypeFilter: ClipboardContentType?

    // MARK: - All-history scope state

    private var scope: HistoryScope = .thisWindow
    private var allHistoryState: AllHistoryState = .browse([])
    /// Rows currently backing the table in all-history scope. Kept separate
    /// from the state so `.searching`/`.preparingIndex` can leave the last
    /// results on screen instead of flashing an empty table per keystroke.
    private var archiveRows: [ClipboardIndexSearchResult] = []
    /// Serial background queue for every index/reader touch in all-history
    /// scope; the main thread never runs a query or a day-file decode.
    private let archiveQueue = DispatchQueue(
        label: "app.clipboardarchive.panel.archive-search"
    )
    /// Debounce (250 ms) + generation counter: only the newest generation's
    /// completion is applied; anything older is dropped as stale.
    private var pendingQueryWork: DispatchWorkItem?
    private var queryGeneration = 0
    private var completedQueryGeneration = 0
    private var detailFetchGeneration = 0
    private var completedDetailFetchGeneration = 0
    private var maintenanceInFlight = false
    /// Cache of the fetched full event/content for the selected archive row
    /// so Copy does not refetch what the detail pane already loaded.
    private var archiveDetailEvent: StoredClipboardEvent?
    private var archiveDetailContent: String?

    private let searchField = NSSearchField()
    private let historySubtitle = NSTextField(labelWithString: "")
    private let typeFilter = NSSegmentedControl()
    private let scopeControl = NSSegmentedControl()
    private let dateFilterPopup = NSPopUpButton()
    private let appFilterPopup = NSPopUpButton()
    private let archiveFilterRow = NSStackView()
    private let rebuildIndexButton = NSButton(title: "Rebuild Search Index", target: nil, action: nil)
    private let tableView = HistoryResultsTableView()
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
        recentItemLimit: Int,
        historyWindow: ClipboardHistoryWindow,
        copyToPasteboard: @escaping (String) -> Void
    ) {
        self.archiveRoot = archiveRoot
        self.reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        self.redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
        self.derivedIndex = ClipboardDerivedIndex(archiveRoot: archiveRoot)
        self.copyToPasteboard = copyToPasteboard
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
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: false)
        } else {
            applyFilter()
        }
    }

    func performAutomationTypeFilter(_ filter: String) {
        let segment = ["all", "text", "links", "code"]
            .firstIndex(of: filter.lowercased()) ?? 0
        typeFilter.selectedSegment = segment
        typeFilter.performClick(nil)
    }

    func performAutomationScope(_ scopeName: String) {
        scopeControl.selectedSegment = scopeName.lowercased() == "all-history" ? 1 : 0
        scopeChanged()
    }

    func performAutomationDateFilter(_ title: String) {
        guard let index = Self.dateFilterTitles
            .firstIndex(where: { $0.lowercased() == title.lowercased() }) else {
            return
        }
        dateFilterPopup.selectItem(at: index)
        archiveFiltersChanged()
    }

    func performAutomationAppFilter(_ appName: String) {
        if appFilterPopup.itemTitles.contains(appName) {
            appFilterPopup.selectItem(withTitle: appName)
        } else {
            appFilterPopup.addItem(withTitle: appName)
            appFilterPopup.selectItem(withTitle: appName)
        }
        archiveFiltersChanged()
    }

    /// True when no archive query or detail fetch is pending or in flight.
    /// The harness polls this (0.1 s steps, 5 s cap) instead of sleeping a
    /// fixed interval.
    var automationIsSettled: Bool {
        guard scope == .allHistory else {
            return true
        }
        if maintenanceInFlight {
            return false
        }
        if completedQueryGeneration < queryGeneration {
            return false
        }
        if completedDetailFetchGeneration < detailFetchGeneration {
            return false
        }
        switch allHistoryState {
        case .searching, .preparingIndex:
            return false
        default:
            return true
        }
    }

    var automationStateName: String {
        guard scope == .allHistory else {
            return "working-window"
        }
        switch allHistoryState {
        case .browse:
            return "browse"
        case .searching:
            return "searching"
        case .results:
            return "results"
        case .empty:
            return "empty"
        case .error:
            return "error"
        case .preparingIndex:
            return "preparingIndex"
        }
    }

    var automationVisibleResultIDs: [String] {
        scope == .allHistory ? archiveRows.map(\.id) : filteredEvents.map(\.id)
    }

    var automationRowCount: Int {
        scope == .allHistory ? archiveRows.count : filteredEvents.count
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

        scopeControl.segmentCount = 2
        scopeControl.setLabel("This Window", forSegment: 0)
        scopeControl.setLabel("All History", forSegment: 1)
        scopeControl.segmentStyle = .rounded
        scopeControl.trackingMode = .selectOne
        scopeControl.selectedSegment = 0
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.setAccessibilityLabel("Search scope")
        listStack.addArrangedSubview(scopeControl)
        scopeControl.widthAnchor.constraint(
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

        // All-history-only filter row (hidden in This Window scope).
        dateFilterPopup.addItems(withTitles: Self.dateFilterTitles)
        dateFilterPopup.target = self
        dateFilterPopup.action = #selector(archiveFiltersChanged)
        dateFilterPopup.setAccessibilityLabel("Filter history by date range")
        appFilterPopup.addItem(withTitle: Self.allAppsFilterTitle)
        appFilterPopup.target = self
        appFilterPopup.action = #selector(archiveFiltersChanged)
        appFilterPopup.setAccessibilityLabel("Filter history by app")
        archiveFilterRow.orientation = .horizontal
        archiveFilterRow.alignment = .centerY
        archiveFilterRow.spacing = 8
        archiveFilterRow.addArrangedSubview(dateFilterPopup)
        archiveFilterRow.addArrangedSubview(appFilterPopup)
        archiveFilterRow.addArrangedSubview(NSView())
        archiveFilterRow.isHidden = true
        listStack.addArrangedSubview(archiveFilterRow)
        archiveFilterRow.widthAnchor.constraint(
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
        // Return in the list commits a copy through the shared
        // no-re-capture path — in both scopes.
        tableView.onReturnKey = { [weak self] in
            self?.copySelected()
        }
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

        // Recovery affordance for all-history scope: shown when a clip can
        // no longer be fetched by id or the search errors; rebuilding the
        // disposable index is always the recovery path.
        rebuildIndexButton.target = self
        rebuildIndexButton.action = #selector(rebuildSearchIndex)
        rebuildIndexButton.bezelStyle = .rounded
        rebuildIndexButton.isHidden = true
        rebuildIndexButton.setAccessibilityLabel("Rebuild the archive search index")
        detailStack.addArrangedSubview(rebuildIndexButton)

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
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: false)
        } else {
            applyFilter()
        }
    }

    // MARK: - All-history scope (contract 3)

    private static let allAppsFilterTitle = "All Apps"
    private static let dateFilterTitles = [
        "Any Time", "Today", "Last 7 Days", "Last 30 Days", "Last 90 Days", "This Year"
    ]

    @objc private func scopeChanged() {
        let requested: HistoryScope = scopeControl.selectedSegment == 1 ? .allHistory : .thisWindow
        guard requested != scope else {
            return
        }
        scope = requested
        archiveDetailEvent = nil
        archiveDetailContent = nil
        switch scope {
        case .thisWindow:
            // Cancel pending archive work and restore the existing
            // in-memory path UNCHANGED.
            pendingQueryWork?.cancel()
            pendingQueryWork = nil
            queryGeneration += 1
            completedQueryGeneration = queryGeneration
            detailFetchGeneration += 1
            completedDetailFetchGeneration = detailFetchGeneration
            archiveFilterRow.isHidden = true
            rebuildIndexButton.isHidden = true
            historySubtitle.stringValue = "\(historyWindow.displayName) · local to this Mac"
            applyFilter()
        case .allHistory:
            archiveFilterRow.isHidden = false
            historySubtitle.stringValue = "All history · local to this Mac"
            populateAppFilter()
            scheduleArchiveQuery(debounced: false)
        }
    }

    @objc private func archiveFiltersChanged() {
        guard scope == .allHistory else {
            return
        }
        scheduleArchiveQuery(debounced: false)
    }

    @objc private func rebuildSearchIndex() {
        guard !maintenanceInFlight else {
            return
        }
        maintenanceInFlight = true
        rebuildIndexButton.isHidden = true
        setAllHistoryState(.preparingIndex)
        let index = derivedIndex
        archiveQueue.async { @Sendable [weak self] in
            let failure: String?
            do {
                _ = try index.rebuild()
                failure = nil
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.maintenanceInFlight = false
                    if let failure {
                        self.setAllHistoryState(.error(failure))
                    } else if self.scope == .allHistory {
                        self.populateAppFilter()
                        self.scheduleArchiveQuery(debounced: false)
                    }
                }
            }
        }
    }

    /// One query pipeline for both browse (empty query) and search. Every
    /// keystroke debounces 250 ms; the generation counter drops stale
    /// completions; all index work runs on the serial background queue.
    private func scheduleArchiveQuery(debounced: Bool) {
        guard scope == .allHistory else {
            return
        }
        pendingQueryWork?.cancel()
        queryGeneration += 1
        let generation = queryGeneration
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let filters = currentArchiveFilters()
        let index = derivedIndex
        setAllHistoryState(.searching)
        let work = DispatchWorkItem { @Sendable [weak self] in
            // First entry after a schema bump (or a missing index) triggers
            // a full rebuild; surface the dedicated state while it runs.
            if !index.schemaIsCurrent() {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.queryGeneration == generation else {
                            return
                        }
                        self.setAllHistoryState(.preparingIndex)
                    }
                }
            }
            var outcome: AllHistoryState
            do {
                try index.ensureCurrentSchema()
                let rows = query.isEmpty
                    ? try index.browse(filters: filters, limit: 200)
                    : try index.structuredSearch(query, filters: filters, limit: 200)
                if rows.isEmpty {
                    outcome = .empty
                } else {
                    outcome = query.isEmpty ? .browse(rows) : .results(rows)
                }
            } catch {
                outcome = .error("\(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.completedQueryGeneration = max(self.completedQueryGeneration, generation)
                    guard self.queryGeneration == generation, self.scope == .allHistory else {
                        return // stale generation — drop
                    }
                    self.setAllHistoryState(outcome)
                }
            }
        }
        pendingQueryWork = work
        if debounced {
            archiveQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            archiveQueue.async(execute: work)
        }
    }

    private func setAllHistoryState(_ state: AllHistoryState) {
        allHistoryState = state
        switch state {
        case let .browse(rows), let .results(rows):
            archiveRows = rows
        case .empty, .error:
            archiveRows = []
        case .searching, .preparingIndex:
            // Keep the previous rows on screen while work is in flight so
            // typing does not flash an empty table.
            break
        }
        guard scope == .allHistory else {
            return
        }
        tableView.reloadData()
        if !archiveRows.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateStatus()
        updateDetail()
    }

    private func currentArchiveFilters() -> ClipboardIndexSearchFilters {
        var filters = ClipboardIndexSearchFilters()
        filters.since = selectedSinceDate()
        let appTitle = appFilterPopup.titleOfSelectedItem ?? Self.allAppsFilterTitle
        if appTitle != Self.allAppsFilterTitle {
            filters.sourceAppName = appTitle
        }
        filters.contentType = contentTypeFilter?.rawValue
        return filters
    }

    private func selectedSinceDate() -> Date? {
        let calendar = Calendar.current
        let now = Date()
        switch dateFilterPopup.indexOfSelectedItem {
        case 1:
            return calendar.startOfDay(for: now)
        case 2:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case 3:
            return calendar.date(byAdding: .day, value: -30, to: now)
        case 4:
            return calendar.date(byAdding: .day, value: -90, to: now)
        case 5:
            return calendar.date(from: calendar.dateComponents([.year], from: now))
        default:
            return nil
        }
    }

    /// Refreshes the app filter popup from the index, preserving the
    /// current selection when the app is still present.
    private func populateAppFilter() {
        let index = derivedIndex
        archiveQueue.async { @Sendable [weak self] in
            let apps = (try? index.distinctSourceApps()) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    let selected = self.appFilterPopup.titleOfSelectedItem
                    self.appFilterPopup.removeAllItems()
                    self.appFilterPopup.addItem(withTitle: Self.allAppsFilterTitle)
                    self.appFilterPopup.addItems(withTitles: apps)
                    if let selected, self.appFilterPopup.itemTitles.contains(selected) {
                        self.appFilterPopup.selectItem(withTitle: selected)
                    }
                }
            }
        }
    }

    private func selectedArchiveResult() -> ClipboardIndexSearchResult? {
        let row = tableView.selectedRow
        guard row >= 0, row < archiveRows.count else {
            return nil
        }
        return archiveRows[row]
    }

    /// Background fetch of the selected result's full event + content via
    /// the single-day-file by-id lookup (never a full archive scan).
    private func fetchArchiveDetail(for result: ClipboardIndexSearchResult) {
        detailFetchGeneration += 1
        let generation = detailFetchGeneration
        let reader = reader
        let id = result.id
        archiveQueue.async { @Sendable [weak self] in
            let event = try? reader.event(withID: id)
            let content = event.flatMap { try? reader.content(for: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    self.completedDetailFetchGeneration = max(
                        self.completedDetailFetchGeneration,
                        generation
                    )
                    guard self.detailFetchGeneration == generation,
                          self.scope == .allHistory,
                          self.selectedArchiveResult()?.id == id else {
                        return
                    }
                    if let event, let content {
                        self.archiveDetailEvent = event
                        self.archiveDetailContent = content
                        self.renderArchiveDetail(event: event, content: content)
                    } else {
                        // Ledger drift or a pruned day file: the index row
                        // is stale. Suppression already hid it from fetch;
                        // offer the rebuild recovery affordance.
                        self.archiveDetailEvent = nil
                        self.archiveDetailContent = nil
                        self.copyButton.isEnabled = false
                        self.detailTitle.stringValue = "Clip unavailable"
                        self.detailMetadata.stringValue = "This clip is no longer in the archive."
                        self.detailTextView.string = "This clip is no longer in the archive."
                        self.rebuildIndexButton.isHidden = false
                    }
                }
            }
        }
    }

    private func renderArchiveDetail(event: StoredClipboardEvent, content: String) {
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
        detailTextView.string = content
        copyButton.isEnabled = true
    }

    private func copySelectedArchiveResult() {
        guard let result = selectedArchiveResult() else {
            return
        }
        if let event = archiveDetailEvent, event.id == result.id,
           let content = archiveDetailContent {
            copyToPasteboard(content)
            statusLabel.stringValue = "Copied to clipboard"
            return
        }
        let reader = reader
        let id = result.id
        archiveQueue.async { @Sendable [weak self] in
            let event = try? reader.event(withID: id)
            let content = event.flatMap { try? reader.content(for: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    if let content {
                        // Same shared no-re-capture path as every copy
                        // surface.
                        self.copyToPasteboard(content)
                        self.statusLabel.stringValue = "Copied to clipboard"
                    } else {
                        self.statusLabel.stringValue = "This clip is no longer in the archive."
                        self.rebuildIndexButton.isHidden = false
                    }
                }
            }
        }
    }

    /// Esc behavior (design): first Esc clears the query; a second Esc in
    /// All History returns to This Window.
    private func handleSearchFieldEscape() -> Bool {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            if scope == .allHistory {
                scheduleArchiveQuery(debounced: false)
            } else {
                applyFilter()
            }
            return true
        }
        if scope == .allHistory {
            scopeControl.selectedSegment = 0
            scopeChanged()
            return true
        }
        return false
    }

    private func focusResultsTable() {
        guard tableView.numberOfRows > 0 else {
            return
        }
        if tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        window?.makeFirstResponder(tableView)
    }

    @objc private func openArchive() {
        NSWorkspace.shared.open(archiveRoot)
    }

    @objc private func copySelected() {
        if scope == .allHistory {
            copySelectedArchiveResult()
            return
        }
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
        copyToPasteboard(content)
        statusLabel.stringValue = contents.count == 1 ? "Copied to clipboard" : "Copied \(contents.count) items"
    }

    @objc private func deleteSelected() {
        // Deletion stays a This Window operation in this slice; bulk and
        // archive-wide deletion land with the bulk-management slice.
        guard scope == .thisWindow else {
            return
        }
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
        if scope == .thisWindow {
            historySubtitle.stringValue = "\(historyWindow.displayName) · local to this Mac"
        }
        let since = Calendar.current.date(
            byAdding: .day,
            value: -historyWindow.dayCount,
            to: Date()
        ) ?? Date()
        events = (try? reader.recentItems(since: since, limit: recentItemLimit)) ?? []
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: false)
        } else {
            applyFilter()
        }
    }

    private func applyFilter() {
        guard scope == .thisWindow else {
            return
        }
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
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: true)
        } else {
            applyFilter()
        }
    }

    /// Keyboard-first routing for the search field: ↓ jumps focus into the
    /// results table; Esc clears the query, then (in All History) returns
    /// to This Window.
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === searchField else {
            return false
        }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            focusResultsTable()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            return handleSearchFieldEscape()
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        scope == .allHistory ? archiveRows.count : filteredEvents.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if scope == .allHistory {
            guard row < archiveRows.count else {
                return nil
            }
            let result = archiveRows[row]
            return historyCell(
                contentType: ClipboardContentType(rawValue: result.contentType),
                previewText: result.snippet,
                metadataText: "\(result.sourceApp)  ·  \(relativeDate(result.capturedAt))"
            )
        }
        guard row < filteredEvents.count else {
            return nil
        }
        let event = filteredEvents[row]
        return historyCell(
            contentType: event.contentType,
            previewText: event.contentPreview,
            metadataText: "\(event.sourceApp.name)  ·  \(relativeDate(event.capturedAt))"
        )
    }

    private func historyCell(
        contentType: ClipboardContentType,
        previewText: String,
        metadataText: String
    ) -> NSView {
        let cell = NSTableCellView()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName(for: contentType),
            accessibilityDescription: contentType.rawValue
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let metadata = NSTextField(labelWithString: metadataText)
        metadata.font = .systemFont(ofSize: 11, weight: .medium)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        metadata.alignment = .left

        let preview = NSTextField(labelWithString: singleLine(previewText))
        preview.font = contentType == .code
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
        if scope == .allHistory {
            switch allHistoryState {
            case .searching:
                statusLabel.stringValue = "Searching…"
            case .preparingIndex:
                statusLabel.stringValue = "Preparing search index…"
            case .empty:
                statusLabel.stringValue = "No matching clips in the archive"
            case .error:
                statusLabel.stringValue = "Search failed"
            case let .browse(rows):
                statusLabel.stringValue = "\(rows.count) archived clip\(rows.count == 1 ? "" : "s")"
            case let .results(rows):
                statusLabel.stringValue = "\(rows.count) match\(rows.count == 1 ? "" : "es")"
            }
            return
        }
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

    private func updateArchiveDetail() {
        deleteButton.isEnabled = false
        detailCapturedValue.stringValue = "—"
        detailFormatValue.stringValue = "—"
        detailSizeValue.stringValue = "—"
        detailCardHeightConstraint?.constant = 150
        guard let result = selectedArchiveResult() else {
            copyButton.isEnabled = false
            detailTextView.string = ""
            switch allHistoryState {
            case .preparingIndex:
                detailTitle.stringValue = "Preparing search index…"
                detailMetadata.stringValue = "The first all-history search builds the index once."
            case let .error(message):
                detailTitle.stringValue = "Search failed"
                detailMetadata.stringValue = message
                rebuildIndexButton.isHidden = false
            case .empty:
                detailTitle.stringValue = "No matching clips"
                detailMetadata.stringValue = "Try a different search or filter."
            case .searching:
                detailTitle.stringValue = "Searching…"
                detailMetadata.stringValue = "Looking through your full archive."
            case .browse, .results:
                detailTitle.stringValue = "Select an item"
                detailMetadata.stringValue = "Choose a clip to preview its full text."
            }
            return
        }
        if case .error = allHistoryState {
            // keep the recovery affordance visible
        } else {
            rebuildIndexButton.isHidden = true
        }
        if let event = archiveDetailEvent, event.id == result.id,
           let content = archiveDetailContent {
            renderArchiveDetail(event: event, content: content)
            return
        }
        copyButton.isEnabled = true
        detailTitle.stringValue = result.sourceApp
        detailMetadata.stringValue = "Copied \(relativeDate(result.capturedAt))"
        detailCapturedValue.stringValue = fullDate(result.capturedAt)
        detailFormatValue.stringValue = result.contentType.capitalized
        detailSizeValue.stringValue = ByteCountFormatter.string(
            fromByteCount: Int64(result.byteCount),
            countStyle: .file
        )
        detailTextView.string = "Loading clip…"
        fetchArchiveDetail(for: result)
    }

    private func updateDetail() {
        if scope == .allHistory {
            updateArchiveDetail()
            return
        }
        rebuildIndexButton.isHidden = true
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
        case .other:
            return "questionmark.square.dashed"
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
