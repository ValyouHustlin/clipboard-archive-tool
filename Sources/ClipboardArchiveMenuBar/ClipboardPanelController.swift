import ClipboardArchiveCore
import AppKit
import Foundation

/// Table subclass so a plain Return keypress in the results list commits a
/// copy through the shared no-re-capture path (keyboard-first contract;
/// works in both scopes), and →/← toggle duplicate-group expansion.
final class HistoryResultsTableView: NSTableView {
    var onReturnKey: (() -> Void)?
    /// Right/left arrow handling for duplicate groups. Return true when the
    /// key was consumed (a group row expanded/collapsed).
    var onExpandKey: ((_ expand: Bool) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, let onReturnKey {
            onReturnKey()
            return
        }
        if event.keyCode == 124, onExpandKey?(true) == true {
            return
        }
        if event.keyCode == 123, onExpandKey?(false) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Window subclass so ⌘P toggles the pin on the current selection. This is
/// an accessory app with no main menu, so the key equivalent has to be
/// intercepted at the window level (`performKeyEquivalent`).
final class HistoryPanelWindow: NSWindow {
    var onPinKeyEquivalent: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "p",
           onPinKeyEquivalent?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class ClipboardPanelController: NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate,
    NSTokenFieldDelegate,
    NSMenuDelegate {
    /// Archive-state mutations this window performs. The app delegate keys
    /// its shared-cache invalidation off the case: every mutation dirties
    /// the quick-picker cache; removing a pin ALSO resets the retention
    /// estimate (an unpin shrinks the exempt set, so the in-memory count
    /// could undercount and silently stop enforcing retention).
    enum ArchiveMutation {
        case eventsDeleted
        case annotationsChanged(pinRemoved: Bool)
    }

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

    /// Collection popup selection (client-side hash filtering, both scopes).
    private enum CollectionScope: Equatable {
        case all
        case pinned
        case snippets
        case collection(id: String)
    }

    /// One display row after duplicate grouping. Indexes point into the
    /// current flat source array (`filteredEvents` or `archiveRows`).
    private struct GroupRowInfo {
        var hash: String
        /// Newest first.
        var indices: [Int]
        var firstCapturedAt: Date
        var lastCapturedAt: Date
    }

    private enum HistoryRow {
        case single(Int)
        case group(GroupRowInfo)
        case occurrence(Int, groupHash: String)
    }

    private let archiveRoot: URL
    private let reader: ClipboardArchiveReader
    private let redactor: ClipboardArchiveRedactor
    private let annotations: ClipboardAnnotationsStore
    private let occurrenceResolver: ClipboardOccurrenceResolver
    /// Notifies the app delegate after this window mutates archive state so
    /// shared caches (quick picker warm list, retention estimate) stay
    /// truthful. One funnel for deletes AND annotation changes.
    private let onArchiveMutation: (ArchiveMutation) -> Void
    /// Persists the "Group duplicates" toggle into settings (the app
    /// delegate owns the settings file; the panel never writes it directly).
    private let onGroupDuplicatesChanged: (Bool) -> Void
    private let derivedIndex: ClipboardDerivedIndex
    /// Shared copy-back paths owned by the app delegate (main.swift). Both
    /// set the pasteboard AND update the capture dedup state so a copy from
    /// this window is not re-captured as a new event. The panel must never
    /// write to the pasteboard directly.
    /// Event-based (Slice 6): single-clip copies restore original rich
    /// representations (image bytes, RTF, file URLs, colors, titled links).
    private let copyEventToPasteboard: (StoredClipboardEvent) -> Void
    /// Plain-text path: multi-select joins stay plain text (documented —
    /// joining rich representations has no meaningful pasteboard shape).
    private let copyPlainTextToPasteboard: (String) -> Void
    /// Whether capture is currently on (Slice 9): the zero-clips empty
    /// state uses it to say honestly that capture may be off instead of
    /// implying clips will appear.
    private let isCaptureEnabled: () -> Bool
    private var events: [StoredClipboardEvent] = []
    private var filteredEvents: [StoredClipboardEvent] = []
    private var recentItemLimit: Int
    private var historyWindow: ClipboardHistoryWindow
    private var contentTypeFilter: ClipboardContentType?

    // MARK: - Annotation / grouping state

    private var pinnedHashes: Set<String> = []
    private var snippetHashes: Set<String> = []
    /// Hashes carrying the manual "restricted" sensitivity override
    /// (Slice 5): visible with an eye.slash badge, never searchable.
    private var restrictedHashes: Set<String> = []
    /// Hashes with a pending sensitivity expiry (Slice 5).
    private var expiringHashes: Set<String> = []
    private var knownCollections: [ClipboardAnnotationCollection] = []
    private var collectionScope: CollectionScope = .all
    private var groupDuplicates: Bool
    private var displayRows: [HistoryRow] = []
    /// Expansion is per-hash and resets on reload/scope change.
    private var expandedGroupHashes: Set<String> = []
    /// The content hash currently backing the tags field / collection
    /// pulldown, captured when the detail pane was populated so an edit
    /// commits to the item it was typed against.
    private var detailContentHash: String?

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
    private let collectionPopup = NSPopUpButton()
    private let groupDuplicatesCheckbox = NSButton(
        checkboxWithTitle: "Group duplicates",
        target: nil,
        action: nil
    )
    private let dateFilterPopup = NSPopUpButton()
    private let appFilterPopup = NSPopUpButton()
    private let archiveFilterRow = NSStackView()
    private let rebuildIndexButton = NSButton(title: "Rebuild Search Index", target: nil, action: nil)
    private let tableView = HistoryResultsTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailTitle = NSTextField(labelWithString: "Select an item")
    private let detailMetadata = NSTextField(labelWithString: "Choose a clip to preview its full text.")
    private let detailTextView = NSTextView()
    /// Rich detail surfaces (Slice 6): image thumbnails and color swatches
    /// render here; the text scroll hides while this is visible.
    private let detailImageView = NSImageView()
    private let detailScrollView = NSScrollView()
    /// Generation guard for async thumbnail fetches: only the newest
    /// generation's completion may touch the image view.
    private var richDetailGeneration = 0
    /// True while a thumbnail fetch is in flight (harness settling).
    private var richDetailPending = false
    private let detailCapturedValue = NSTextField(labelWithString: "—")
    private let detailFormatValue = NSTextField(labelWithString: "—")
    private let detailSizeValue = NSTextField(labelWithString: "—")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let sensitiveButton = NSButton(title: "", target: nil, action: nil)
    private let tagsField = NSTokenField()
    private let collectionMembershipButton = NSPopUpButton()
    private var detailCardHeightConstraint: NSLayoutConstraint?

    // MARK: - Edit-before-copy sheet state (Slice 7)

    private var editSheet: NSWindow?
    private var editSheetTextView: NSTextView?
    private var editSheetCopyButton: NSButton?

    init(
        archiveRoot: URL,
        recentItemLimit: Int,
        historyWindow: ClipboardHistoryWindow,
        groupDuplicates: Bool = false,
        copyEventToPasteboard: @escaping (StoredClipboardEvent) -> Void,
        copyPlainTextToPasteboard: @escaping (String) -> Void,
        isCaptureEnabled: @escaping () -> Bool = { true },
        onArchiveMutation: @escaping (ArchiveMutation) -> Void = { _ in },
        onGroupDuplicatesChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.archiveRoot = archiveRoot
        self.reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        self.redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
        self.annotations = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        self.occurrenceResolver = ClipboardOccurrenceResolver(archiveRoot: archiveRoot)
        self.derivedIndex = ClipboardDerivedIndex(archiveRoot: archiveRoot)
        self.copyEventToPasteboard = copyEventToPasteboard
        self.copyPlainTextToPasteboard = copyPlainTextToPasteboard
        self.isCaptureEnabled = isCaptureEnabled
        self.onArchiveMutation = onArchiveMutation
        self.onGroupDuplicatesChanged = onGroupDuplicatesChanged
        self.recentItemLimit = recentItemLimit
        self.historyWindow = historyWindow
        self.groupDuplicates = groupDuplicates

        let window = HistoryPanelWindow(
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
        window.onPinKeyEquivalent = { [weak self] in
            guard let self else {
                return false
            }
            // Never steal ⌘P from an active text edit: toggling a pin
            // refreshes the annotation controls, which would overwrite an
            // uncommitted tag token or search text mid-typing.
            if let responder = self.window?.firstResponder as? NSTextView,
               responder.delegate === self.tagsField
                || responder.delegate === self.searchField {
                return false
            }
            return self.togglePinOnSelection()
        }
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
        // Snapshot fidelity (Slice 9): production windows draw their own
        // background, but cached bitmaps composite the non-layer-backed
        // content view's transparent regions as white — illegible with
        // dark-appearance text. Fill with the appearance-resolved window
        // background first. DEBUG-only path.
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

    func performAutomationSearch(_ query: String) {
        searchField.stringValue = query
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: false)
        } else {
            applyFilter()
        }
    }

    func performAutomationTypeFilter(_ filter: String) {
        let segment = ["all", "text", "links", "code", "images", "files"]
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

    func performAutomationGroupDuplicates(_ enabled: Bool) {
        groupDuplicatesCheckbox.state = enabled ? .on : .off
        groupDuplicatesToggled()
    }

    func performAutomationCollectionFilter(_ title: String) {
        guard collectionPopup.itemTitles.contains(title) else {
            return
        }
        collectionPopup.selectItem(withTitle: title)
        collectionScopeChanged()
    }

    /// Routes a named gesture through the SAME production handlers the UI
    /// uses so automation exercises real paths.
    func performAutomationHistoryGesture(_ gesture: String) {
        switch gesture.trimmingCharacters(in: .whitespaces).lowercased() {
        case "select-first":
            selectDisplayRow(0)
        case "select-last":
            selectDisplayRow(displayRows.count - 1)
        case "pin-selected":
            setPinned(true, forContentHashes: selectedContentHashes())
        case "unpin-selected":
            // Bypasses the snippet confirm alert (none of the harness
            // fixtures are snippets); production path otherwise.
            setPinned(false, forContentHashes: selectedContentHashes())
        case "expand-group":
            _ = toggleSelectedGroup(expand: true)
        case "collapse-group":
            _ = toggleSelectedGroup(expand: false)
        case "copy-selected":
            copySelected()
        case "mark-restricted-selected":
            setRestricted(true, forContentHashes: selectedContentHashes())
        case "clear-sensitivity-selected":
            clearSensitivity(forContentHashes: selectedContentHashes())
        case "expire-selected-hour":
            setExpiry(afterHours: 1, forContentHashes: selectedContentHashes())
        case "expire-selected-past":
            // Harness-only: writes an ALREADY-DUE expiry through the
            // production store API so the sweep receipt can fire without
            // waiting an hour.
            for hash in selectedContentHashes() {
                try? annotations.setExpiry(Date().addingTimeInterval(-3_600), forContentHash: hash)
            }
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            refreshAfterAnnotationChange()
        case "select-first-two":
            // Multi-select gesture for the join receipt.
            if displayRows.count >= 2 {
                tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            }
        case "edit-before-copy-commit":
            // Slice 7 receipt: open the production sheet, edit the text,
            // and commit through the production Copy button — proving the
            // pasteboard gets the EDIT while the archive stays unchanged.
            presentEditBeforeCopySheet()
            editSheetTextView?.string += " — edited for automation"
            editSheetCopyButton?.performClick(nil)
        case let gesture where gesture.hasPrefix("copy-as:"):
            // Slice 7 transformation copies through the production funnel.
            if let transform = ClipCopyTransform(
                rawValue: String(gesture.dropFirst("copy-as:".count))
            ) {
                copyTransformedSelection(transform)
            }
        case let gesture where gesture.hasPrefix("join-selected:"):
            if let separator = ClipTransformations.JoinSeparator(
                rawValue: String(gesture.dropFirst("join-selected:".count))
            ) {
                joinSelected(separator)
            }
        case let gesture where gesture.hasPrefix("select-index:"):
            // Rich-detail receipts (Slice 6): select an arbitrary row so
            // the harness can capture one detail render per kind.
            if let index = Int(gesture.dropFirst("select-index:".count)) {
                selectDisplayRow(index)
            }
        default:
            break
        }
    }

    var automationRestrictedVisibleIDs: [String] {
        displayRows.compactMap { row in
            switch row {
            case let .single(index), let .occurrence(index, _):
                guard scope == .thisWindow, index < filteredEvents.count,
                      isRestricted(filteredEvents[index]) else {
                    return nil
                }
                return flatID(at: index)
            case let .group(info):
                guard restrictedHashes.contains(info.hash) else {
                    return nil
                }
                return info.indices.first.flatMap { flatID(at: $0) }
            }
        }
    }

    var automationDetailContentHash: String {
        detailContentHash ?? ""
    }

    /// Index rows currently stored for the detail hash — the
    /// mark-restricted receipt asserts this drops to zero immediately.
    var automationIndexRowCountForDetailHash: Int {
        guard let hash = detailContentHash, !hash.isEmpty else {
            return -1
        }
        return (try? derivedIndex.occurrenceIDs(contentHash: hash).count) ?? -1
    }

    /// True when the FIRST table row's live cell view contains the
    /// restricted badge image (pixel-independent badge receipt).
    var automationRow0ShowsRestrictedBadge: Bool {
        guard tableView.numberOfRows > 0,
              let cell = tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) else {
            return false
        }
        func containsBadge(_ view: NSView) -> Bool {
            if let imageView = view as? NSImageView,
               imageView.image?.accessibilityDescription == "Restricted — hidden from search" {
                return true
            }
            return view.subviews.contains(where: containsBadge)
        }
        return containsBadge(cell)
    }

    /// Selection-independent restricted receipt: total index rows across
    /// EVERY override-restricted hash (must be 0 right after marking).
    var automationRestrictedIndexRowCount: Int {
        guard !restrictedHashes.isEmpty else {
            return -1
        }
        return restrictedHashes.reduce(0) { total, hash in
            total + ((try? derivedIndex.occurrenceIDs(contentHash: hash).count) ?? 0)
        }
    }

    /// True when no archive query or detail fetch is pending or in flight.
    /// The harness polls this (0.1 s steps, 5 s cap) instead of sleeping a
    /// fixed interval.
    var automationIsSettled: Bool {
        // A pending image-thumbnail fetch is unsettled in EITHER scope.
        if richDetailPending {
            return false
        }
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
        displayRows.compactMap { row in
            switch row {
            case let .single(index), let .occurrence(index, _):
                return flatID(at: index)
            case let .group(info):
                return info.indices.first.flatMap { flatID(at: $0) }
            }
        }
    }

    var automationRowCount: Int {
        displayRows.count
    }

    var automationRowKinds: [String] {
        displayRows.map { row in
            switch row {
            case .single:
                return "single"
            case let .group(info):
                return "group:\(info.indices.count)"
            case .occurrence:
                return "occurrence"
            }
        }
    }

    var automationPinnedVisibleIDs: [String] {
        displayRows.compactMap { row in
            switch row {
            case let .single(index), let .occurrence(index, _):
                guard pinnedHashes.contains(flatContentHash(at: index)) else {
                    return nil
                }
                return flatID(at: index)
            case let .group(info):
                guard pinnedHashes.contains(info.hash) else {
                    return nil
                }
                return info.indices.first.flatMap { flatID(at: $0) }
            }
        }
    }

    var automationStatusText: String {
        statusLabel.stringValue
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
        scopeControl.toolTip = "This Window browses the working view; All History searches the full archive index"
        listStack.addArrangedSubview(scopeControl)
        scopeControl.widthAnchor.constraint(
            equalTo: listStack.widthAnchor,
            constant: -28
        ).isActive = true

        // Collections filter (contract 5): All Clips | Pinned | Snippets |
        // named collections | New Collection…, client-side hash filtering
        // in both scopes.
        collectionPopup.target = self
        collectionPopup.action = #selector(collectionScopeChanged)
        collectionPopup.setAccessibilityLabel("Filter history by collection")
        collectionPopup.toolTip = "Show all clips, pinned clips, snippets, or a collection"
        listStack.addArrangedSubview(collectionPopup)
        collectionPopup.widthAnchor.constraint(
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

        // 6 segments (Slice 6). `.richText` surfaces under All — documented:
        // the equality filter cannot OR content types.
        typeFilter.segmentCount = 6
        for (segment, label) in ["All", "Text", "Links", "Code", "Images", "Files"].enumerated() {
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

        groupDuplicatesCheckbox.target = self
        groupDuplicatesCheckbox.action = #selector(groupDuplicatesToggled)
        groupDuplicatesCheckbox.state = groupDuplicates ? .on : .off
        groupDuplicatesCheckbox.font = .systemFont(ofSize: 11)
        groupDuplicatesCheckbox.setAccessibilityLabel("Group duplicate clips")
        groupDuplicatesCheckbox.toolTip = "Collapse repeated copies of the same content into one row"
        listStack.addArrangedSubview(groupDuplicatesCheckbox)

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
        tableView.doubleAction = #selector(rowDoubleClicked)
        // Return in the list commits a copy through the shared
        // no-re-capture path — in both scopes.
        tableView.onReturnKey = { [weak self] in
            self?.copySelected()
        }
        tableView.onExpandKey = { [weak self] expand in
            self?.toggleSelectedGroup(expand: expand) ?? false
        }
        let contextMenu = NSMenu()
        contextMenu.delegate = self
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
        statusLabel.lineBreakMode = .byTruncatingTail
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
        pinButton.target = self
        pinButton.action = #selector(pinButtonClicked)
        pinButton.bezelStyle = .texturedRounded
        pinButton.title = ""
        pinButton.image = NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: "Pin selected clip"
        )
        pinButton.toolTip = "Pin selected clip (⌘P)"
        pinButton.setAccessibilityLabel("Pin selected clip")

        sensitiveButton.target = self
        sensitiveButton.action = #selector(sensitiveButtonClicked(_:))
        sensitiveButton.bezelStyle = .texturedRounded
        sensitiveButton.title = ""
        sensitiveButton.image = NSImage(
            systemSymbolName: "eye.slash",
            accessibilityDescription: "Mark selected clip sensitive"
        )
        sensitiveButton.toolTip = "Mark Sensitive (restricted / expiring)"
        sensitiveButton.setAccessibilityLabel("Mark selected clip sensitive")

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
        actions.addArrangedSubview(sensitiveButton)
        actions.addArrangedSubview(pinButton)
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

        let detailScroll = detailScrollView
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
        // Rich detail surface (Slice 6): same slot as the text scroll; one
        // of the two is hidden at a time.
        detailImageView.imageScaling = .scaleProportionallyUpOrDown
        detailImageView.isHidden = true
        detailImageView.translatesAutoresizingMaskIntoConstraints = false
        contentCard.addSubview(detailImageView)
        let detailCardHeight = contentCard.heightAnchor.constraint(equalToConstant: 150)
        detailCardHeightConstraint = detailCardHeight
        NSLayoutConstraint.activate([
            detailScroll.leadingAnchor.constraint(equalTo: contentCard.leadingAnchor, constant: 18),
            detailScroll.trailingAnchor.constraint(equalTo: contentCard.trailingAnchor, constant: -18),
            detailScroll.topAnchor.constraint(equalTo: contentCard.topAnchor, constant: 12),
            detailScroll.bottomAnchor.constraint(equalTo: contentCard.bottomAnchor, constant: -12),
            detailImageView.leadingAnchor.constraint(equalTo: contentCard.leadingAnchor, constant: 18),
            detailImageView.trailingAnchor.constraint(equalTo: contentCard.trailingAnchor, constant: -18),
            detailImageView.topAnchor.constraint(equalTo: contentCard.topAnchor, constant: 12),
            detailImageView.bottomAnchor.constraint(equalTo: contentCard.bottomAnchor, constant: -12),
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

        // Tags + collection membership (single selection only).
        let organizeRow = NSStackView()
        organizeRow.orientation = .horizontal
        organizeRow.alignment = .firstBaseline
        organizeRow.spacing = 18
        let tagsColumn = NSStackView()
        tagsColumn.orientation = .vertical
        tagsColumn.alignment = .leading
        tagsColumn.spacing = 3
        let tagsLabel = NSTextField(labelWithString: "TAGS")
        tagsLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        tagsLabel.textColor = .tertiaryLabelColor
        tagsField.delegate = self
        tagsField.tokenStyle = .rounded
        tagsField.font = .systemFont(ofSize: 12)
        tagsField.placeholderString = "Add tags"
        tagsField.completionDelay = 0.2
        tagsField.setAccessibilityLabel("Tags for the selected clip")
        tagsField.toolTip = "Comma or Return adds a tag; tags stick to the content, not one copy"
        tagsColumn.addArrangedSubview(tagsLabel)
        tagsColumn.addArrangedSubview(tagsField)
        tagsField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        collectionMembershipButton.pullsDown = true
        collectionMembershipButton.addItem(withTitle: "Add to Collection")
        collectionMembershipButton.setAccessibilityLabel("Add the selected clip to a collection")
        collectionMembershipButton.toolTip = "Add or remove the selected clip from a collection"
        organizeRow.addArrangedSubview(tagsColumn)
        organizeRow.addArrangedSubview(collectionMembershipButton)
        organizeRow.addArrangedSubview(NSView())
        detailStack.addArrangedSubview(organizeRow)
        organizeRow.widthAnchor.constraint(
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
        refreshAnnotationState()
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
        // Adaptive: re-resolves per appearance (Slice 9 QA fix).
        let separator = AdaptiveBackgroundView {
            .separatorColor
        }
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
        case 4:
            contentTypeFilter = .image
        case 5:
            contentTypeFilter = .fileReference
        default:
            contentTypeFilter = nil
        }
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: false)
        } else {
            applyFilter()
        }
    }

    @objc private func groupDuplicatesToggled() {
        groupDuplicates = groupDuplicatesCheckbox.state == .on
        expandedGroupHashes.removeAll()
        onGroupDuplicatesChanged(groupDuplicates)
        if scope == .allHistory {
            // The empty-query data source changes (browse ↔ metaRows), so
            // re-run the query rather than regrouping stale rows.
            scheduleArchiveQuery(debounced: false)
        } else {
            applyFilter()
        }
    }

    // MARK: - Annotation state

    /// Re-reads pins/snippets/collections from the sidecar store (cheap: the
    /// store stat-checks a cached parse) and refreshes the collection popup.
    private func refreshAnnotationState() {
        let document = annotations.document()
        pinnedHashes = Set(document.annotations.filter { $0.value.pinned }.keys)
        snippetHashes = Set(document.annotations.filter { $0.value.snippet }.keys)
        restrictedHashes = Set(
            document.annotations.filter { $0.value.sensitivityOverride == "restricted" }.keys
        )
        expiringHashes = Set(document.annotations.filter { $0.value.expiresAt != nil }.keys)
        knownCollections = document.collections
        populateCollectionPopup()
    }

    /// Restricted display state for one This Window event: stored label
    /// (app-rule store-no-index) OR manual annotation override.
    private func isRestricted(_ event: StoredClipboardEvent) -> Bool {
        event.privacyLabel == .restricted || restrictedHashes.contains(event.contentHash)
    }

    private func populateCollectionPopup() {
        let selectedScope = collectionScope
        collectionPopup.removeAllItems()
        collectionPopup.addItem(withTitle: "All Clips")
        collectionPopup.addItem(withTitle: "Pinned")
        collectionPopup.addItem(withTitle: "Snippets")
        if !knownCollections.isEmpty {
            collectionPopup.menu?.addItem(.separator())
            for collection in knownCollections {
                collectionPopup.addItem(withTitle: collection.name)
                collectionPopup.lastItem?.representedObject = collection.id
            }
        }
        collectionPopup.menu?.addItem(.separator())
        collectionPopup.addItem(withTitle: "New Collection…")
        switch selectedScope {
        case .all:
            collectionPopup.selectItem(at: 0)
        case .pinned:
            collectionPopup.selectItem(at: 1)
        case .snippets:
            collectionPopup.selectItem(at: 2)
        case let .collection(id):
            if let item = collectionPopup.itemArray.first(where: {
                $0.representedObject as? String == id
            }) {
                collectionPopup.select(item)
            } else {
                // The filtered collection was deleted; fall back to all.
                collectionScope = .all
                collectionPopup.selectItem(at: 0)
            }
        }
    }

    @objc private func collectionScopeChanged() {
        guard let item = collectionPopup.selectedItem else {
            return
        }
        if item.title == "New Collection…" {
            promptForNewCollection()
            return
        }
        if let id = item.representedObject as? String {
            collectionScope = .collection(id: id)
        } else {
            switch collectionPopup.indexOfSelectedItem {
            case 1:
                collectionScope = .pinned
            case 2:
                collectionScope = .snippets
            default:
                collectionScope = .all
            }
        }
        expandedGroupHashes.removeAll()
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: false)
        } else {
            applyFilter()
        }
    }

    private func promptForNewCollection() {
        let alert = NSAlert()
        alert.messageText = "New Collection"
        alert.informativeText = "Collections are ordered lists of clips, stored locally."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "Collection name"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !name.isEmpty else {
            populateCollectionPopup()
            return
        }
        do {
            let collection = try annotations.createCollection(named: name)
            collectionScope = .collection(id: collection.id)
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            if scope == .allHistory {
                scheduleArchiveQuery(debounced: false)
            } else {
                applyFilter()
            }
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
            populateCollectionPopup()
        }
    }

    /// Current collection-scope hash constraint. `order` is non-nil only for
    /// named collections, whose `contentHashes` order is the display order.
    private func collectionScopeHashes() -> (hashes: Set<String>, order: [String]?)? {
        switch collectionScope {
        case .all:
            return nil
        case .pinned:
            return (pinnedHashes, nil)
        case .snippets:
            return (snippetHashes, nil)
        case let .collection(id):
            let hashes = knownCollections.first { $0.id == id }?.contentHashes ?? []
            return (Set(hashes), hashes)
        }
    }

    // MARK: - Pinning

    /// The ONE pin/unpin funnel for every surface (context menu, detail
    /// button, ⌘P, automation). Newer-format read-only annotations surface
    /// as a status message, never a crash or silent no-op.
    private func setPinned(_ pinned: Bool, forContentHashes hashes: [String]) {
        let targets = hashes.filter { !$0.isEmpty && (pinnedHashes.contains($0) != pinned) }
        guard !targets.isEmpty else {
            return
        }
        if !pinned {
            let snippetTargets = targets.filter { snippetHashes.contains($0) }
            if !snippetTargets.isEmpty, !confirmUnpinSnippets(count: snippetTargets.count) {
                return
            }
        }
        do {
            for hash in targets {
                try annotations.setPinned(pinned, forContentHash: hash)
            }
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: !pinned))
            refreshAfterAnnotationChange()
            statusLabel.stringValue = pinned
                ? (targets.count == 1 ? "Pinned" : "Pinned \(targets.count) clips")
                : (targets.count == 1 ? "Unpinned" : "Unpinned \(targets.count) clips")
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    private func confirmUnpinSnippets(count: Int) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN"] != nil {
            return true
        }
#endif
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Unpin this snippet?" : "Unpin \(count) snippets?"
        alert.informativeText = "Snippets are always pinned, so unpinning also removes the snippet."
        alert.addButton(withTitle: "Unpin and Remove Snippet")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// ⌘P behavior: if every selected clip is pinned, unpin; otherwise pin.
    /// Returns false when there is nothing to act on (lets the key fall
    /// through).
    @discardableResult
    private func togglePinOnSelection() -> Bool {
        let hashes = selectedContentHashes()
        guard !hashes.isEmpty else {
            return false
        }
        let allPinned = hashes.allSatisfy { pinnedHashes.contains($0) }
        setPinned(!allPinned, forContentHashes: hashes)
        return true
    }

    @objc private func pinButtonClicked() {
        togglePinOnSelection()
    }

    @objc private func sensitiveButtonClicked(_ sender: NSButton) {
        guard !selectedContentHashes().isEmpty else {
            return
        }
        markSensitiveMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    private func annotationsErrorMessage(_ error: Error) -> String {
        if case ClipboardAnnotationsError.newerFormat = error {
            return "Saved by a newer version of Clipboard Archive."
        }
        return "Could not update the annotation"
    }

    /// After any annotation change: re-filter when an annotation-driven
    /// filter is active (membership may have changed), otherwise just
    /// redraw badges and the detail pane.
    private func refreshAfterAnnotationChange() {
        if collectionScope != .all {
            if scope == .allHistory {
                scheduleArchiveQuery(debounced: false)
            } else {
                applyFilter()
            }
            return
        }
        if scope == .thisWindow {
            rebuildDisplayRows()
        }
        // Preserve the selection across the reload: annotation toggles
        // (pin, mark sensitive) do not change row membership in the
        // unfiltered scope, and losing the selection made chained actions
        // silently no-op.
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        if let last = selection.max(), last < displayRows.count {
            tableView.selectRowIndexes(selection, byExtendingSelection: false)
        }
        updateDetail()
    }

    // MARK: - Snippets (creation surface; consumption lives in the picker)

    private func markSelectionAsSnippet() {
        guard let hash = selectedContentHashes().first, selectedContentHashes().count == 1 else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save as Snippet"
        alert.informativeText = "Snippets appear at the top of the Quick Picker. Saving a snippet also pins it."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "Snippet title (optional)"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save Snippet")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do {
            try annotations.setSnippet(true, title: input.stringValue, forContentHash: hash)
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            statusLabel.stringValue = "Saved as snippet"
            refreshAfterAnnotationChange()
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    private func removeSelectionSnippet() {
        guard let hash = selectedContentHashes().first, selectedContentHashes().count == 1 else {
            return
        }
        do {
            try annotations.setSnippet(false, title: nil, forContentHash: hash)
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            statusLabel.stringValue = "Snippet removed (still pinned)"
            refreshAfterAnnotationChange()
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    // MARK: - Mark Sensitive (Slice 5)

    /// Restricted = stored, visible, never searchable. Setting the manual
    /// override immediately removes every live occurrence from the search
    /// index; clearing re-upserts them (reader scan — the index no longer
    /// knows the occurrences).
    private func setRestricted(_ restricted: Bool, forContentHashes hashes: [String]) {
        let targets = hashes.filter { !$0.isEmpty }
        guard !targets.isEmpty else {
            return
        }
        do {
            for hash in targets {
                try annotations.setSensitivityOverride(
                    restricted ? "restricted" : nil,
                    forContentHash: hash
                )
                if restricted {
                    let ids = (try? occurrenceResolver.liveOccurrenceIDs(contentHash: hash)) ?? []
                    _ = try? derivedIndex.delete(eventIDs: ids)
                } else {
                    reindexOccurrences(contentHash: hash)
                }
            }
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            refreshAfterAnnotationChange()
            // After the refresh: re-selecting rows fires updateStatus,
            // which would otherwise clobber this message.
            statusLabel.stringValue = restricted
                ? "Restricted — hidden from search"
                : "Restriction cleared — searchable again"
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    /// Re-upserts every live occurrence of a hash after its restriction is
    /// cleared. Events whose STORED label is `.restricted` (app-rule
    /// store-no-index) stay excluded — the upsert predicate keeps them out.
    private func reindexOccurrences(contentHash: String) {
        let ids = (try? occurrenceResolver.liveOccurrenceIDs(
            contentHash: contentHash,
            viaReaderScan: true
        )) ?? []
        for id in ids {
            guard let event = try? reader.event(withID: id),
                  let content = try? reader.content(for: event) else {
                continue
            }
            try? derivedIndex.upsert(event: event, body: content)
        }
    }

    /// Expiring sensitive clip: at the chosen time the sweeper deletes ALL
    /// occurrences — including pinned ones (stated in the warning).
    private func setExpiry(afterHours hours: Int, forContentHashes hashes: [String]) {
        let targets = hashes.filter { !$0.isEmpty }
        guard !targets.isEmpty else {
            return
        }
        let pinnedTargets = targets.filter { pinnedHashes.contains($0) }
        if !pinnedTargets.isEmpty, !confirmExpiryOverridesPins(count: pinnedTargets.count) {
            return
        }
        let expiresAt = Date().addingTimeInterval(TimeInterval(hours) * 3_600)
        do {
            for hash in targets {
                try annotations.setExpiry(expiresAt, forContentHash: hash)
            }
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            refreshAfterAnnotationChange()
            statusLabel.stringValue = "Will be deleted \(relativeDate(expiresAt)) — enforced at launch, every 30 minutes, and when history opens"
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    private func confirmExpiryOverridesPins(count: Int) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN"] != nil {
            return true
        }
#endif
        let alert = NSAlert()
        alert.messageText = count == 1
            ? "Expire this pinned clip?"
            : "Expire \(count) pinned clips?"
        alert.informativeText = "Expiry overrides pin protection: when the time comes, the clip is deleted even though it is pinned."
        alert.addButton(withTitle: "Set Expiry")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Clears manual sensitivity: override AND pending expiry. Stored
    /// `.restricted` labels (app-rule store-no-index events) are permanent
    /// — event lines are never rewritten.
    private func clearSensitivity(forContentHashes hashes: [String]) {
        let targets = hashes.filter { !$0.isEmpty }
        guard !targets.isEmpty else {
            return
        }
        do {
            for hash in targets {
                let wasRestricted = restrictedHashes.contains(hash)
                try annotations.setSensitivityOverride(nil, forContentHash: hash)
                try annotations.setExpiry(nil, forContentHash: hash)
                if wasRestricted {
                    reindexOccurrences(contentHash: hash)
                }
            }
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            refreshAfterAnnotationChange()
            statusLabel.stringValue = "Sensitivity cleared"
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    @objc private func toggleRestrictedFromMenu() {
        let hashes = selectedContentHashes()
        let allRestricted = !hashes.isEmpty && hashes.allSatisfy { restrictedHashes.contains($0) }
        setRestricted(!allRestricted, forContentHashes: hashes)
    }

    @objc private func expireOneHourFromMenu() {
        setExpiry(afterHours: 1, forContentHashes: selectedContentHashes())
    }

    @objc private func expireOneDayFromMenu() {
        setExpiry(afterHours: 24, forContentHashes: selectedContentHashes())
    }

    @objc private func expireSevenDaysFromMenu() {
        setExpiry(afterHours: 24 * 7, forContentHashes: selectedContentHashes())
    }

    @objc private func clearSensitivityFromMenu() {
        clearSensitivity(forContentHashes: selectedContentHashes())
    }

    /// The shared Mark Sensitive submenu (context menu + detail pane).
    private func markSensitiveMenu() -> NSMenu {
        let menu = NSMenu()
        let hashes = selectedContentHashes()
        let allRestricted = !hashes.isEmpty && hashes.allSatisfy { restrictedHashes.contains($0) }
        let restrictedItem = NSMenuItem(
            title: "Restricted (hidden from search)",
            action: #selector(toggleRestrictedFromMenu),
            keyEquivalent: ""
        )
        restrictedItem.target = self
        restrictedItem.state = allRestricted ? .on : .off
        menu.addItem(restrictedItem)
        menu.addItem(.separator())
        for (title, action) in [
            ("Expire in 1 Hour", #selector(expireOneHourFromMenu)),
            ("Expire in 1 Day", #selector(expireOneDayFromMenu)),
            ("Expire in 7 Days", #selector(expireSevenDaysFromMenu))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clearItem = NSMenuItem(
            title: "Clear Sensitivity",
            action: #selector(clearSensitivityFromMenu),
            keyEquivalent: ""
        )
        clearItem.target = self
        clearItem.isEnabled = hashes.contains {
            restrictedHashes.contains($0) || expiringHashes.contains($0)
        }
        menu.addItem(clearItem)
        return menu
    }

    /// External-mutation refresh hook (expiry sweep, dashboard cleanup,
    /// bulk sheet): reloads the visible history from disk.
    func reloadFromExternalMutation() {
        reload()
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
        expandedGroupHashes.removeAll()
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
    ///
    /// Data-source selection (Slice 4): an empty query normally browses the
    /// newest 200 rows, but duplicate grouping or a collection filter needs
    /// deeper reach, so those use the meta-only `metaRows` query (capped at
    /// 5,000 — surfaced in the footer when hit). NO SQL GROUP BY anywhere:
    /// the deletion ledger cannot be consulted in SQL, so grouping happens
    /// in Swift after read-time suppression.
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
        let needsDeepReach = groupDuplicates || collectionScope != .all
        let hashConstraint = collectionScopeHashes()
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
                var rows: [ClipboardIndexSearchResult]
                if query.isEmpty {
                    rows = needsDeepReach
                        ? try index.metaRows(filters: filters)
                        : try index.browse(filters: filters, limit: 200)
                } else {
                    // Deep reach mirrors the empty-query branch: a collection
                    // member (or duplicate group occurrence) that ranks
                    // outside the top 200 full-text hits must not silently
                    // vanish after the hash post-filter below.
                    rows = try index.structuredSearch(
                        query,
                        filters: filters,
                        limit: needsDeepReach ? 5000 : 200
                    )
                }
                if let hashConstraint {
                    rows = rows.filter { hashConstraint.hashes.contains($0.contentHash) }
                    if let order = hashConstraint.order {
                        // Collection order = contentHashes order; newest
                        // first within the same hash.
                        var position: [String: Int] = [:]
                        for (offset, hash) in order.enumerated() where position[hash] == nil {
                            position[hash] = offset
                        }
                        rows.sort { left, right in
                            let leftPosition = position[left.contentHash] ?? Int.max
                            let rightPosition = position[right.contentHash] ?? Int.max
                            if leftPosition != rightPosition {
                                return leftPosition < rightPosition
                            }
                            return left.capturedAt > right.capturedAt
                        }
                    }
                }
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
        rebuildDisplayRows()
        tableView.reloadData()
        if !displayRows.isEmpty, tableView.selectedRow < 0 {
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

    // MARK: - Display rows (duplicate grouping presentation)

    private var flatCount: Int {
        scope == .allHistory ? archiveRows.count : filteredEvents.count
    }

    private func flatContentHash(at index: Int) -> String {
        if scope == .allHistory {
            guard index < archiveRows.count else {
                return ""
            }
            return archiveRows[index].contentHash
        }
        guard index < filteredEvents.count else {
            return ""
        }
        return filteredEvents[index].contentHash
    }

    private func flatID(at index: Int) -> String? {
        if scope == .allHistory {
            guard index < archiveRows.count else {
                return nil
            }
            return archiveRows[index].id
        }
        guard index < filteredEvents.count else {
            return nil
        }
        return filteredEvents[index].id
    }

    private func flatCapturedAt(at index: Int) -> Date {
        if scope == .allHistory {
            guard index < archiveRows.count else {
                return .distantPast
            }
            return archiveRows[index].capturedAt
        }
        guard index < filteredEvents.count else {
            return .distantPast
        }
        return filteredEvents[index].capturedAt
    }

    /// Adapter so the Core grouping engine can group flat-array positions.
    private struct IndexedGroupable: ClipboardDuplicateGroupable {
        var index: Int
        var hash: String
        var capturedAt: Date

        var duplicateContentHash: String { hash }
        var duplicateCapturedAt: Date { capturedAt }
    }

    /// Grouping is presentation over the CURRENT flat rows: the existing
    /// filter predicate has already run, so group counts are honest about
    /// what survived filtering (and read-time suppression in All History).
    private func rebuildDisplayRows() {
        let count = flatCount
        guard groupDuplicates else {
            displayRows = (0..<count).map { .single($0) }
            return
        }
        let items = (0..<count).map {
            IndexedGroupable(index: $0, hash: flatContentHash(at: $0), capturedAt: flatCapturedAt(at: $0))
        }
        var rows: [HistoryRow] = []
        for grouped in ClipboardDuplicateGrouping.rows(grouping: items) {
            switch grouped {
            case let .single(item):
                rows.append(.single(item.index))
            case let .group(group):
                let info = GroupRowInfo(
                    hash: group.contentHash,
                    indices: group.occurrences.map(\.index),
                    firstCapturedAt: group.firstCapturedAt,
                    lastCapturedAt: group.lastCapturedAt
                )
                rows.append(.group(info))
                if expandedGroupHashes.contains(group.contentHash) {
                    for occurrence in group.occurrences {
                        rows.append(.occurrence(occurrence.index, groupHash: group.contentHash))
                    }
                }
            }
        }
        displayRows = rows
    }

    private func selectDisplayRow(_ row: Int) {
        guard row >= 0, row < displayRows.count else {
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    /// Representative flat index for a display row: singles and occurrences
    /// map directly; a collapsed group maps to its NEWEST occurrence.
    private func representativeFlatIndex(forRow row: Int) -> Int? {
        guard row >= 0, row < displayRows.count else {
            return nil
        }
        switch displayRows[row] {
        case let .single(index), let .occurrence(index, _):
            return index
        case let .group(info):
            return info.indices.first
        }
    }

    private func selectionContainsGroupRow() -> Bool {
        tableView.selectedRowIndexes.contains { row in
            if row < displayRows.count, case .group = displayRows[row] {
                return true
            }
            return false
        }
    }

    /// Unique content hashes covered by the selection (group rows contribute
    /// their group hash). Empty hashes (pre-hash index rows) are dropped.
    private func selectedContentHashes() -> [String] {
        var seen = Set<String>()
        var hashes: [String] = []
        for row in tableView.selectedRowIndexes.sorted() {
            guard row < displayRows.count else {
                continue
            }
            let hash: String
            switch displayRows[row] {
            case let .single(index), let .occurrence(index, _):
                hash = flatContentHash(at: index)
            case let .group(info):
                hash = info.hash
            }
            if !hash.isEmpty, seen.insert(hash).inserted {
                hashes.append(hash)
            }
        }
        return hashes
    }

    @discardableResult
    private func toggleSelectedGroup(expand: Bool) -> Bool {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < displayRows.count else {
            return false
        }
        switch displayRows[selectedRow] {
        case let .group(info):
            if expand, !expandedGroupHashes.contains(info.hash) {
                expandedGroupHashes.insert(info.hash)
            } else if !expand, expandedGroupHashes.contains(info.hash) {
                expandedGroupHashes.remove(info.hash)
            } else {
                return false
            }
            rebuildDisplayRows()
            tableView.reloadData()
            selectRowForGroupHash(info.hash)
            updateStatus()
            updateDetail()
            return true
        case let .occurrence(_, groupHash):
            guard !expand else {
                return false
            }
            expandedGroupHashes.remove(groupHash)
            rebuildDisplayRows()
            tableView.reloadData()
            selectRowForGroupHash(groupHash)
            updateStatus()
            updateDetail()
            return true
        case .single:
            return false
        }
    }

    private func selectRowForGroupHash(_ hash: String) {
        guard let row = displayRows.firstIndex(where: {
            if case let .group(info) = $0 {
                return info.hash == hash
            }
            return false
        }) else {
            return
        }
        selectDisplayRow(row)
    }

    private func toggleGroup(atRow row: Int) {
        guard row >= 0, row < displayRows.count, case let .group(info) = displayRows[row] else {
            return
        }
        if expandedGroupHashes.contains(info.hash) {
            expandedGroupHashes.remove(info.hash)
        } else {
            expandedGroupHashes.insert(info.hash)
        }
        rebuildDisplayRows()
        tableView.reloadData()
        selectRowForGroupHash(info.hash)
        updateStatus()
        updateDetail()
    }

    @objc private func chevronClicked(_ sender: NSButton) {
        toggleGroup(atRow: sender.tag)
    }

    @objc private func rowDoubleClicked() {
        let clicked = tableView.clickedRow
        if clicked >= 0, clicked < displayRows.count, case .group = displayRows[clicked] {
            toggleGroup(atRow: clicked)
            return
        }
        copySelected()
    }

    private func selectedArchiveResult() -> ClipboardIndexSearchResult? {
        guard scope == .allHistory,
              let index = representativeFlatIndex(forRow: tableView.selectedRow),
              index < archiveRows.count else {
            return nil
        }
        return archiveRows[index]
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
                        self.showPlainDetailSurface()
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
        detailFormatValue.stringValue = formatLabel(for: event)
        detailSizeValue.stringValue = ByteCountFormatter.string(
            fromByteCount: Int64(event.byteCount),
            countStyle: .file
        )
        detailCardHeightConstraint?.constant = preferredDetailCardHeight(for: event)
        renderDetailContent(for: event, plainContent: content)
        copyButton.isEnabled = true
    }

    private func copySelectedArchiveResult() {
        guard let result = selectedArchiveResult() else {
            return
        }
        if let event = archiveDetailEvent, event.id == result.id {
            copyEventToPasteboard(event)
            statusLabel.stringValue = "Copied to clipboard"
            return
        }
        let reader = reader
        let id = result.id
        archiveQueue.async { @Sendable [weak self] in
            let event = try? reader.event(withID: id)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    if let event {
                        // Same shared no-re-capture path as every copy
                        // surface (event-based since Slice 6).
                        self.copyEventToPasteboard(event)
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
            // A collapsed group copies its NEWEST occurrence via the shared
            // no-re-capture path (representative mapping).
            copySelectedArchiveResult()
            return
        }
        let selected = selectedEvents()
        guard !selected.isEmpty else {
            return
        }
        if selected.count == 1, let event = selected.first {
            // Single selection: event-based copy restores original rich
            // representations (Slice 6).
            copyEventToPasteboard(event)
            statusLabel.stringValue = "Copied to clipboard"
            return
        }
        let contents = selected.compactMap { try? reader.content(for: $0) }
        guard !contents.isEmpty else {
            statusLabel.stringValue = "Could not read the selected item"
            return
        }
        // Multi-select stays a plain-text join of the fallbacks (documented).
        copyPlainTextToPasteboard(contents.joined(separator: "\n\n"))
        statusLabel.stringValue = "Copied \(contents.count) items"
    }

    // MARK: - Clip actions (Slice 7)

    /// UI-side naming for the Core transformations. The math lives in
    /// `ClipTransformations`; this enum only maps menu titles and DEBUG
    /// automation names onto it.
    private enum ClipCopyTransform: String, CaseIterable {
        case plainText = "plain"
        case cleanedLinks = "cleaned-links"
        case normalizedWhitespace = "normalized-whitespace"
        case strippedFormatting = "stripped-formatting"

        var menuTitle: String {
            switch self {
            case .plainText:
                return "Plain Text"
            case .cleanedLinks:
                return "Cleaned Links"
            case .normalizedWhitespace:
                return "Normalized Whitespace"
            case .strippedFormatting:
                return "Stripped Formatting"
            }
        }

        var statusLabel: String {
            switch self {
            case .plainText:
                return "Copied as plain text"
            case .cleanedLinks:
                return "Copied with tracking parameters removed"
            case .normalizedWhitespace:
                return "Copied with normalized whitespace"
            case .strippedFormatting:
                return "Copied with formatting stripped"
            }
        }

        func apply(_ text: String) -> String {
            switch self {
            case .plainText:
                return ClipTransformations.plainText(from: text)
            case .cleanedLinks:
                return ClipTransformations.cleanURL(text)
            case .normalizedWhitespace:
                return ClipTransformations.normalizeWhitespace(text)
            case .strippedFormatting:
                return ClipTransformations.stripFormatting(text)
            }
        }
    }

    /// Plain-text contents backing the current selection, for the
    /// transformation copies. This Window resolves every selected event
    /// through the reader; All History only offers clip actions once the
    /// detail fetch for a SINGLE selection has loaded (no synchronous
    /// archive reads on the UI thread — contract 3).
    private func selectedTransformableContents() -> [String] {
        if scope == .allHistory {
            guard let result = selectedArchiveResult(),
                  let event = archiveDetailEvent, event.id == result.id,
                  let content = archiveDetailContent else {
                return []
            }
            return [content]
        }
        return selectedEvents().compactMap { try? reader.content(for: $0) }
    }

    private func canTransformSelection() -> Bool {
        if scope == .allHistory {
            guard let result = selectedArchiveResult() else {
                return false
            }
            return archiveDetailEvent?.id == result.id && archiveDetailContent != nil
        }
        return !selectedEvents().isEmpty
    }

    /// Single-selection guard for Edit Before Copy.
    private func isSingleTransformableSelection() -> Bool {
        if scope == .allHistory {
            return canTransformSelection()
        }
        return selectedEvents().count == 1
    }

    /// The one transformation-copy funnel: transformed text ALWAYS routes
    /// through the shared no-re-capture plain-text path. Multi-select
    /// mirrors the plain Copy behavior (blank line between clips) before
    /// the transformation is applied.
    private func copyTransformedSelection(_ transform: ClipCopyTransform) {
        let contents = selectedTransformableContents()
        guard !contents.isEmpty else {
            statusLabel.stringValue = "Could not read the selected item"
            return
        }
        let combined = contents.count == 1
            ? contents[0]
            : contents.joined(separator: "\n\n")
        copyPlainTextToPasteboard(transform.apply(combined))
        statusLabel.stringValue = transform.statusLabel
    }

    @objc private func copyAsFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let transform = ClipCopyTransform(rawValue: raw) else {
            return
        }
        copyTransformedSelection(transform)
    }

    /// Joins the selected clips (This Window, 2+) with a standard separator
    /// through the shared no-re-capture plain-text path.
    private func joinSelected(_ separator: ClipTransformations.JoinSeparator) {
        guard scope == .thisWindow else {
            return
        }
        let contents = selectedEvents().compactMap { try? reader.content(for: $0) }
        guard contents.count >= 2 else {
            statusLabel.stringValue = "Select at least two clips to join"
            return
        }
        copyPlainTextToPasteboard(ClipTransformations.join(contents, separator: separator))
        statusLabel.stringValue = "Joined \(contents.count) clips to the clipboard"
    }

    @objc private func joinSelectedFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let separator = ClipTransformations.JoinSeparator(rawValue: raw) else {
            return
        }
        joinSelected(separator)
    }

    @objc private func editBeforeCopyFromMenu() {
        presentEditBeforeCopySheet()
    }

    // MARK: - Edit before copy (Slice 7)

    /// Sheet with an editable copy of the clip. The edited text is COPIED
    /// through the shared no-re-capture plain-text path and NEVER written
    /// back to the archive: the archive is immutable history (append +
    /// tombstone redaction only), so no code path here rewrites an event
    /// line or body file.
    private func presentEditBeforeCopySheet() {
        guard editSheet == nil,
              let window,
              isSingleTransformableSelection(),
              let content = selectedTransformableContents().first else {
            return
        }
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Edit Before Copy"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Edit Before Copy")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(
            labelWithString: "Edits are copied, not saved to history."
        )
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.string = content
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.frame = scroll.contentView.bounds
        scroll.documentView = textView
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let cancelButton = NSButton(
            title: "Cancel",
            target: self,
            action: #selector(editSheetCancelClicked)
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        // ⌘↩ commits (plain Return stays with the text view for newlines).
        let copyButton = NSButton(
            title: "Copy",
            target: self,
            action: #selector(editSheetCopyClicked)
        )
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]
        copyButton.toolTip = "Copy the edited text (⌘↩)"
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(copyButton)
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        sheet.contentView = contentView

        editSheet = sheet
        editSheetTextView = textView
        editSheetCopyButton = copyButton
        window.beginSheet(sheet)
        sheet.makeFirstResponder(textView)
    }

    @objc private func editSheetCopyClicked() {
        let text = editSheetTextView?.string ?? ""
        // Shared no-re-capture path; the archive is never touched.
        copyPlainTextToPasteboard(text)
        statusLabel.stringValue = "Edited copy placed on the clipboard"
        closeEditSheet()
    }

    @objc private func editSheetCancelClicked() {
        closeEditSheet()
    }

    private func closeEditSheet() {
        if let editSheet {
            window?.endSheet(editSheet)
        }
        editSheet = nil
        editSheetTextView = nil
        editSheetCopyButton = nil
    }

    @objc private func deleteSelected() {
        // Deletion stays a This Window operation; archive-wide deletion
        // lives in the Bulk Cleanup sheet.
        guard scope == .thisWindow else {
            return
        }
        // Delete is DISABLED on collapsed group rows: a group hides N
        // copies behind one row. Expand the group to delete copies.
        guard !selectionContainsGroupRow() else {
            statusLabel.stringValue = "Expand the group to delete individual copies"
            return
        }
        let selected = selectedEvents()
        guard !selected.isEmpty else {
            return
        }

        // Slice 5 reroute: multi-select deletion flows through the ONE bulk
        // engine path, so the confirmation shows the SAME truthful numbers
        // (count + reclaimed bytes) the execution will report.
        let engine = ClipboardBulkEngine(archiveRoot: archiveRoot)
        var criteria = ClipboardBulkCriteria(eventIDs: Set(selected.map(\.id)))
        guard var preview = try? engine.preview(criteria) else {
            statusLabel.stringValue = "Could not preview the deletion"
            return
        }

        if preview.matchedEvents == 0, preview.exemptedPinnedEvents > 0 {
            // Everything selected is pinned. Deleting pinned content is the
            // explicit, SEPARATELY confirmed override (contract 5).
            criteria.includePinned = true
            guard let pinnedPreview = try? engine.preview(criteria) else {
                statusLabel.stringValue = "Could not preview the deletion"
                return
            }
            let alert = NSAlert()
            alert.messageText = pinnedPreview.matchedEvents == 1
                ? "Delete this pinned clip?"
                : "Delete \(pinnedPreview.matchedEvents) pinned clips?"
            alert.informativeText = "Pins normally protect clips from deletion. Deleting reclaims \(byteString(pinnedPreview.reclaimedBytes)) and cannot be undone. Deleting the last copy also removes its pin, tags, and snippet."
            alert.addButton(withTitle: pinnedPreview.matchedEvents == 1 ? "Delete Pinned Clip" : "Delete Pinned Clips")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            preview = pinnedPreview
        } else {
            let alert = NSAlert()
            alert.messageText = preview.matchedEvents == 1
                ? "Delete this clip?"
                : "Delete \(preview.matchedEvents) clips?"
            var informative = "Deletes the stored content, reclaiming \(byteString(preview.reclaimedBytes)). This cannot be undone. Timeline metadata remains."
            if preview.exemptedPinnedEvents > 0 {
                informative += " \(preview.exemptedPinnedEvents) pinned clip\(preview.exemptedPinnedEvents == 1 ? "" : "s") in the selection will be kept (unpin first to delete them)."
            }
            if preview.removedAnnotationHashes > 0 {
                informative += " Deleting the last copy of annotated content also removes its tags and collections."
            }
            alert.informativeText = informative
            alert.addButton(withTitle: preview.matchedEvents == 1 ? "Delete Clip" : "Delete Clips")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        }

        do {
            let result = try engine.execute(criteria)
            onArchiveMutation(.eventsDeleted)
            reload()
            var status = result.matchedEvents == 1
                ? "Clip deleted · reclaimed \(byteString(result.reclaimedBytes))"
                : "\(result.matchedEvents) clips deleted · reclaimed \(byteString(result.reclaimedBytes))"
            if result.exemptedPinnedEvents > 0 {
                status += " · \(result.exemptedPinnedEvents) pinned kept"
            }
            statusLabel.stringValue = status
        } catch {
            onArchiveMutation(.eventsDeleted)
            statusLabel.stringValue = "Delete failed"
        }
    }

    private func byteString(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func reload() {
        refreshAnnotationState()
        expandedGroupHashes.removeAll()
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
        let hashConstraint = collectionScopeHashes()
        filteredEvents = events.filter { event in
            let matchesType = contentTypeFilter.map { event.contentType == $0 } ?? true
            let matchesCollection = hashConstraint.map {
                $0.hashes.contains(event.contentHash)
            } ?? true
            let matchesQuery = query.isEmpty || [
                event.contentPreview,
                event.sourceApp.name,
                event.contentType.rawValue
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(query)
            return matchesType && matchesCollection && matchesQuery
        }
        if let order = hashConstraint?.order {
            var position: [String: Int] = [:]
            for (offset, hash) in order.enumerated() where position[hash] == nil {
                position[hash] = offset
            }
            filteredEvents.sort { left, right in
                let leftPosition = position[left.contentHash] ?? Int.max
                let rightPosition = position[right.contentHash] ?? Int.max
                if leftPosition != rightPosition {
                    return leftPosition < rightPosition
                }
                return left.capturedAt > right.capturedAt
            }
        }
        rebuildDisplayRows()
        tableView.reloadData()
        if let previousID,
           let row = displayRows.firstIndex(where: { displayRow in
               representativeID(of: displayRow) == previousID
           }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !displayRows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateStatus()
        updateDetail()
    }

    private func representativeID(of row: HistoryRow) -> String? {
        switch row {
        case let .single(index), let .occurrence(index, _):
            return flatID(at: index)
        case let .group(info):
            return info.indices.first.flatMap { flatID(at: $0) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as AnyObject?) === searchField else {
            return
        }
        if scope == .allHistory {
            scheduleArchiveQuery(debounced: true)
        } else {
            applyFilter()
        }
    }

    /// Tags commit on end-editing against the hash the field was populated
    /// with (single selection only).
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as AnyObject?) === tagsField,
              let hash = detailContentHash, !hash.isEmpty else {
            return
        }
        let tokens = (tagsField.objectValue as? [String]) ?? []
        let normalized = ClipboardAnnotationsStore.normalizedTags(tokens)
        let existing = annotations.annotation(for: hash)?.tags ?? []
        guard normalized != existing else {
            return
        }
        do {
            try annotations.setTags(normalized, forContentHash: hash)
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            statusLabel.stringValue = normalized.isEmpty ? "Tags cleared" : "Tags saved"
            refreshAfterAnnotationChange()
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    /// Tag completions come from every tag already in the store.
    func tokenField(
        _ tokenField: NSTokenField,
        completionsForSubstring substring: String,
        indexOfToken tokenIndex: Int,
        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
        let lowered = substring.lowercased()
        return annotations.allTags().filter { $0.lowercased().hasPrefix(lowered) }
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

    // MARK: - Context menu (pin state aware)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let copyItem = NSMenuItem(
            title: "Copy Selected",
            action: #selector(copySelected),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)

        // Clip actions (Slice 7): Copy As, Join Selected, Edit Before Copy.
        // Every one of these copies through the shared no-re-capture
        // plain-text path; none of them ever writes back into the archive.
        if canTransformSelection() {
            let copyAs = NSMenuItem(title: "Copy As", action: nil, keyEquivalent: "")
            let copyAsSubmenu = NSMenu()
            for transform in ClipCopyTransform.allCases {
                let item = NSMenuItem(
                    title: transform.menuTitle,
                    action: #selector(copyAsFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = transform.rawValue
                copyAsSubmenu.addItem(item)
            }
            copyAs.submenu = copyAsSubmenu
            menu.addItem(copyAs)

            if scope == .thisWindow, selectedEvents().count >= 2 {
                let join = NSMenuItem(title: "Join Selected", action: nil, keyEquivalent: "")
                let joinSubmenu = NSMenu()
                for separator in ClipTransformations.JoinSeparator.allCases {
                    let item = NSMenuItem(
                        title: separator.displayName,
                        action: #selector(joinSelectedFromMenu(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = separator.rawValue
                    joinSubmenu.addItem(item)
                }
                join.submenu = joinSubmenu
                menu.addItem(join)
            }

            if isSingleTransformableSelection() {
                let edit = NSMenuItem(
                    title: "Edit Before Copy…",
                    action: #selector(editBeforeCopyFromMenu),
                    keyEquivalent: ""
                )
                edit.target = self
                menu.addItem(edit)
            }
        }

        let hashes = selectedContentHashes()
        if !hashes.isEmpty {
            let allPinned = hashes.allSatisfy { pinnedHashes.contains($0) }
            let title: String
            if hashes.count == 1 {
                title = allPinned ? "Unpin" : "Pin"
            } else {
                title = allPinned ? "Unpin \(hashes.count) Clips" : "Pin \(hashes.count) Clips"
            }
            let pinItem = NSMenuItem(
                title: title,
                action: allPinned ? #selector(unpinFromMenu) : #selector(pinFromMenu),
                keyEquivalent: "p"
            )
            pinItem.target = self
            menu.addItem(pinItem)

            if hashes.count == 1, let hash = hashes.first {
                if snippetHashes.contains(hash) {
                    let snippetItem = NSMenuItem(
                        title: "Remove Snippet",
                        action: #selector(removeSnippetFromMenu),
                        keyEquivalent: ""
                    )
                    snippetItem.target = self
                    menu.addItem(snippetItem)
                } else {
                    let snippetItem = NSMenuItem(
                        title: "Save as Snippet…",
                        action: #selector(makeSnippetFromMenu),
                        keyEquivalent: ""
                    )
                    snippetItem.target = self
                    menu.addItem(snippetItem)
                }
            }

            // Mark Sensitive (Slice 5): restricted toggle + expiry + clear.
            let sensitiveItem = NSMenuItem(title: "Mark Sensitive", action: nil, keyEquivalent: "")
            sensitiveItem.submenu = markSensitiveMenu()
            menu.addItem(sensitiveItem)
        }

        menu.addItem(.separator())
        let deleteItem = NSMenuItem(
            title: "Delete Selected…",
            action: #selector(deleteSelected),
            keyEquivalent: ""
        )
        deleteItem.target = self
        if scope != .thisWindow || selectionContainsGroupRow() {
            deleteItem.action = nil
            deleteItem.isEnabled = false
            deleteItem.toolTip = scope == .thisWindow
                ? "Expand the group to delete individual copies"
                : "Delete from the This Window scope"
        }
        menu.addItem(deleteItem)
    }

    @objc private func pinFromMenu() {
        setPinned(true, forContentHashes: selectedContentHashes())
    }

    @objc private func unpinFromMenu() {
        setPinned(false, forContentHashes: selectedContentHashes())
    }

    @objc private func makeSnippetFromMenu() {
        markSelectionAsSnippet()
    }

    @objc private func removeSnippetFromMenu() {
        removeSelectionSnippet()
    }

    @objc private func collectionMembershipToggled(_ sender: NSMenuItem) {
        guard let hash = detailContentHash, !hash.isEmpty,
              let collectionID = sender.representedObject as? String else {
            return
        }
        let isMember = knownCollections
            .first { $0.id == collectionID }?
            .contentHashes.contains(hash) ?? false
        do {
            try annotations.setMembership(contentHash: hash, inCollection: collectionID, isMember: !isMember)
            refreshAnnotationState()
            onArchiveMutation(.annotationsChanged(pinRemoved: false))
            statusLabel.stringValue = isMember ? "Removed from collection" : "Added to collection"
            refreshAfterAnnotationChange()
        } catch {
            statusLabel.stringValue = annotationsErrorMessage(error)
        }
    }

    @objc private func newCollectionFromMembership() {
        promptForNewCollection()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayRows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < displayRows.count else {
            return nil
        }
        switch displayRows[row] {
        case let .single(index):
            return flatCell(at: index, indented: false)
        case let .occurrence(index, _):
            return flatCell(at: index, indented: true)
        case let .group(info):
            return groupCell(info: info, row: row)
        }
    }

    private func flatCell(at index: Int, indented: Bool) -> NSView? {
        if scope == .allHistory {
            guard index < archiveRows.count else {
                return nil
            }
            let result = archiveRows[index]
            return historyCell(
                contentType: ClipboardContentType(rawValue: result.contentType),
                previewText: result.snippet,
                metadataText: "\(result.sourceApp)  ·  \(relativeDate(result.capturedAt))",
                pinned: pinnedHashes.contains(result.contentHash),
                restricted: restrictedHashes.contains(result.contentHash),
                indented: indented
            )
        }
        guard index < filteredEvents.count else {
            return nil
        }
        let event = filteredEvents[index]
        return historyCell(
            contentType: event.contentType,
            previewText: event.contentPreview,
            metadataText: "\(event.sourceApp.name)  ·  \(relativeDate(event.capturedAt))",
            pinned: pinnedHashes.contains(event.contentHash),
            restricted: isRestricted(event),
            indented: indented
        )
    }

    private func historyCell(
        contentType: ClipboardContentType,
        previewText: String,
        metadataText: String,
        pinned: Bool = false,
        restricted: Bool = false,
        indented: Bool = false
    ) -> NSView {
        let cell = NSTableCellView()
        let leadingInset: CGFloat = indented ? 34 : 10

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

        var trailingAnchor = cell.trailingAnchor
        var trailingConstant: CGFloat = -10
        if pinned {
            let badge = NSImageView()
            badge.image = NSImage(
                systemSymbolName: "pin.fill",
                accessibilityDescription: "Pinned"
            )
            badge.contentTintColor = .systemOrange
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 12),
                badge.heightAnchor.constraint(equalToConstant: 12)
            ])
            trailingAnchor = badge.leadingAnchor
            trailingConstant = -6
        }
        if restricted {
            // Restricted badge (Slice 5): stored and visible, hidden from
            // search.
            let badge = NSImageView()
            badge.image = NSImage(
                systemSymbolName: "eye.slash",
                accessibilityDescription: "Restricted — hidden from search"
            )
            badge.contentTintColor = .systemPurple
            badge.toolTip = "Restricted: stored and visible, hidden from search"
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailingConstant),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 14),
                badge.heightAnchor.constraint(equalToConstant: 12)
            ])
            trailingAnchor = badge.leadingAnchor
            trailingConstant = -6
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leadingInset),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            preview.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailingConstant),
            preview.topAnchor.constraint(equalTo: cell.topAnchor, constant: 11),
            metadata.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            metadata.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 4)
        ])
        return cell
    }

    /// Group header row: preview of the newest copy, a "×N" count capsule,
    /// an expand chevron, and honest first/latest metadata.
    private func groupCell(info: GroupRowInfo, row: Int) -> NSView? {
        guard let newestIndex = info.indices.first else {
            return nil
        }
        let contentType: ClipboardContentType
        let previewText: String
        if scope == .allHistory {
            guard newestIndex < archiveRows.count else {
                return nil
            }
            let result = archiveRows[newestIndex]
            contentType = ClipboardContentType(rawValue: result.contentType)
            previewText = result.snippet
        } else {
            guard newestIndex < filteredEvents.count else {
                return nil
            }
            let event = filteredEvents[newestIndex]
            contentType = event.contentType
            previewText = event.contentPreview
        }

        let cell = NSTableCellView()
        let expanded = expandedGroupHashes.contains(info.hash)

        let chevron = NSButton(title: "", target: self, action: #selector(chevronClicked(_:)))
        chevron.bezelStyle = .inline
        chevron.isBordered = false
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Collapse duplicates" : "Expand duplicates"
        )
        chevron.tag = row
        chevron.setAccessibilityLabel(expanded ? "Collapse duplicate group" : "Expand duplicate group")
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: symbolName(for: contentType),
            accessibilityDescription: contentType.rawValue
        )
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSTextField(labelWithString: singleLine(previewText))
        preview.font = contentType == .code
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 13)
        preview.lineBreakMode = .byTruncatingTail
        preview.translatesAutoresizingMaskIntoConstraints = false

        let capsule = NSTextField(labelWithString: "×\(info.indices.count)")
        capsule.font = .systemFont(ofSize: 10, weight: .semibold)
        capsule.textColor = .secondaryLabelColor
        capsule.alignment = .center
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        capsule.layer?.cornerRadius = 7
        capsule.translatesAutoresizingMaskIntoConstraints = false

        let metadataText = "\(info.indices.count) copies · first \(relativeDate(info.firstCapturedAt)) · latest \(relativeDate(info.lastCapturedAt))"
        let metadata = NSTextField(labelWithString: metadataText)
        metadata.font = .systemFont(ofSize: 11, weight: .medium)
        metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        metadata.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(chevron)
        cell.addSubview(icon)
        cell.addSubview(preview)
        cell.addSubview(capsule)
        cell.addSubview(metadata)

        var previewTrailingAnchor = cell.trailingAnchor
        var previewTrailingConstant: CGFloat = -10
        if pinnedHashes.contains(info.hash) {
            let badge = NSImageView()
            badge.image = NSImage(
                systemSymbolName: "pin.fill",
                accessibilityDescription: "Pinned"
            )
            badge.contentTintColor = .systemOrange
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 12),
                badge.heightAnchor.constraint(equalToConstant: 12)
            ])
            previewTrailingAnchor = badge.leadingAnchor
            previewTrailingConstant = -6
        }

        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            preview.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            preview.topAnchor.constraint(equalTo: cell.topAnchor, constant: 11),
            capsule.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 6),
            capsule.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            capsule.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            capsule.trailingAnchor.constraint(lessThanOrEqualTo: previewTrailingAnchor, constant: previewTrailingConstant),
            metadata.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            metadata.trailingAnchor.constraint(equalTo: previewTrailingAnchor, constant: previewTrailingConstant),
            metadata.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 4)
        ])
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        updateDetail()
    }

    private func selectedEvents() -> [StoredClipboardEvent] {
        guard scope == .thisWindow else {
            return []
        }
        var seen = Set<String>()
        var selected: [StoredClipboardEvent] = []
        for row in tableView.selectedRowIndexes.sorted() {
            guard let index = representativeFlatIndex(forRow: row),
                  index < filteredEvents.count else {
                continue
            }
            let event = filteredEvents[index]
            if seen.insert(event.id).inserted {
                selected.append(event)
            }
        }
        return selected
    }

    private func updateStatus() {
        var capSuffix = ""
        if scope == .allHistory,
           groupDuplicates || collectionScope != .all,
           archiveRows.count >= ClipboardDerivedIndex.metaRowsMaximumLimit {
            capSuffix = " · grouped over the most recent 5,000 clips"
        }
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
                // All History footer note (Slice 5): restricted clips are
                // stored and visible in This Window but never enter the
                // search index this scope reads.
                if groupDuplicates {
                    let groupCount = displayRows.filter {
                        if case .group = $0 {
                            return true
                        }
                        return false
                    }.count
                    statusLabel.stringValue = "\(rows.count) archived clip\(rows.count == 1 ? "" : "s") · \(groupCount) duplicate group\(groupCount == 1 ? "" : "s")\(capSuffix) · Restricted clips are hidden from search."
                } else {
                    statusLabel.stringValue = "\(rows.count) archived clip\(rows.count == 1 ? "" : "s")\(capSuffix) · Restricted clips are hidden from search."
                }
            case let .results(rows):
                statusLabel.stringValue = "\(rows.count) match\(rows.count == 1 ? "" : "es")\(capSuffix) · Restricted clips are hidden from search."
            }
            return
        }
        let selectedCount = tableView.selectedRowIndexes.count
        let total = filteredEvents.count
        let isFiltered = !searchField.stringValue.isEmpty
            || contentTypeFilter != nil
            || collectionScope != .all
        let base = !isFiltered
            ? "\(total) clip\(total == 1 ? "" : "s")"
            : "\(total) match\(total == 1 ? "" : "es")"
        statusLabel.stringValue = selectedCount > 1
            ? "\(base) · \(selectedCount) selected"
            : base
    }

    // MARK: - Detail pane

    /// Detail-pane annotation controls: pin button state, tags field, and
    /// collection membership pulldown for the current single-selection hash.
    private func updateAnnotationControls(contentHash: String?) {
        detailContentHash = contentHash
        let hasHash = !(contentHash?.isEmpty ?? true)
        pinButton.isEnabled = !selectedContentHashes().isEmpty
        let selectionPinned = !selectedContentHashes().isEmpty
            && selectedContentHashes().allSatisfy { pinnedHashes.contains($0) }
        pinButton.image = NSImage(
            systemSymbolName: selectionPinned ? "pin.fill" : "pin",
            accessibilityDescription: selectionPinned ? "Unpin selected clip" : "Pin selected clip"
        )
        pinButton.contentTintColor = selectionPinned ? .systemOrange : nil
        pinButton.toolTip = selectionPinned ? "Unpin selected clip (⌘P)" : "Pin selected clip (⌘P)"

        tagsField.isEnabled = hasHash
        if let contentHash, hasHash {
            tagsField.objectValue = annotations.annotation(for: contentHash)?.tags ?? []
        } else {
            tagsField.objectValue = []
        }

        collectionMembershipButton.isEnabled = hasHash
        sensitiveButton.isEnabled = !selectedContentHashes().isEmpty
        rebuildCollectionMembershipMenu(contentHash: hasHash ? contentHash : nil)
    }

    private func rebuildCollectionMembershipMenu(contentHash: String?) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Add to Collection", action: nil, keyEquivalent: ""))
        for collection in knownCollections {
            let item = NSMenuItem(
                title: collection.name,
                action: #selector(collectionMembershipToggled(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = collection.id
            if let contentHash, collection.contentHashes.contains(contentHash) {
                item.state = .on
            }
            menu.addItem(item)
        }
        if !knownCollections.isEmpty {
            menu.addItem(.separator())
        }
        let newItem = NSMenuItem(
            title: "New Collection…",
            action: #selector(newCollectionFromMembership),
            keyEquivalent: ""
        )
        newItem.target = self
        menu.addItem(newItem)
        collectionMembershipButton.menu = menu
    }

    private func updateArchiveDetail() {
        deleteButton.isEnabled = false
        deleteButton.toolTip = "Deletion works in the This Window scope"
        detailCapturedValue.stringValue = "—"
        detailFormatValue.stringValue = "—"
        detailSizeValue.stringValue = "—"
        detailCardHeightConstraint?.constant = 150
        guard let result = selectedArchiveResult() else {
            copyButton.isEnabled = false
            updateAnnotationControls(contentHash: nil)
            showPlainDetailSurface()
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
        updateAnnotationControls(contentHash: result.contentHash)
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
        showPlainDetailSurface()
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
        let hasCollapsedGroup = selectionContainsGroupRow()
        deleteButton.isEnabled = !selected.isEmpty && !hasCollapsedGroup
        deleteButton.toolTip = hasCollapsedGroup
            ? "Expand the group to delete individual copies"
            : "Delete selected clips"
        detailCapturedValue.stringValue = "—"
        detailFormatValue.stringValue = "—"
        detailSizeValue.stringValue = "—"
        detailCardHeightConstraint?.constant = 150

        guard selected.count == 1, let event = selected.first else {
            updateAnnotationControls(contentHash: nil)
            showPlainDetailSurface()
            if selected.count > 1 {
                detailTitle.stringValue = "\(selected.count) clips selected"
                detailMetadata.stringValue = "Copy combines them with a blank line between each clip."
            } else if events.isEmpty {
                detailTitle.stringValue = "No clips yet"
                // Honest first-run hint (Slice 9): if capture is off or
                // paused, copying will NOT make clips appear — say so.
                detailMetadata.stringValue = isCaptureEnabled()
                    ? "Copy text in any app and it will appear here."
                    : "Capture is off or paused — turn it on from the menu bar icon or Settings, then copy some text."
            } else {
                detailTitle.stringValue = "No matching clips"
                detailMetadata.stringValue = "Try a different search."
            }
            detailTextView.string = ""
            return
        }

        updateAnnotationControls(contentHash: event.contentHash)
        detailTitle.stringValue = event.sourceApp.name
        var metadataText = "Copied \(relativeDate(event.capturedAt))"
        if case let .group(info)? = tableView.selectedRowIndexes.first.flatMap({ row in
            row < displayRows.count ? displayRows[row] : nil
        }), info.indices.count > 1 {
            metadataText = "\(info.indices.count) copies · newest \(relativeDate(info.lastCapturedAt))"
        }
        detailMetadata.stringValue = metadataText
        detailCapturedValue.stringValue = fullDate(event.capturedAt)
        detailFormatValue.stringValue = formatLabel(for: event)
        detailSizeValue.stringValue = ByteCountFormatter.string(
            fromByteCount: Int64(event.byteCount),
            countStyle: .file
        )
        detailCardHeightConstraint?.constant = preferredDetailCardHeight(for: event)
        renderDetailContent(
            for: event,
            plainContent: (try? reader.content(for: event)) ?? event.contentPreview
        )
    }

    private func preferredDetailCardHeight(for event: StoredClipboardEvent) -> CGFloat {
        switch event.richContent?.kind {
        case ClipboardRichContent.imageKind:
            return 280
        case ClipboardRichContent.colorKind:
            return 190
        default:
            break
        }
        let wrappedLineEstimate = Int(ceil(Double(event.characterCount) / 64.0))
        let visibleLines = max(event.lineCount, wrappedLineEstimate)
        return min(220, max(112, CGFloat(68 + min(visibleLines, 7) * 22)))
    }

    // MARK: - Rich detail rendering (Slice 6)

    /// Restores the plain-text detail surface and invalidates any in-flight
    /// thumbnail fetch (generation guard).
    private func showPlainDetailSurface() {
        richDetailGeneration += 1
        richDetailPending = false
        detailImageView.isHidden = true
        detailImageView.image = nil
        detailScrollView.isHidden = false
    }

    /// Per-kind detail rendering shared by BOTH scopes. `plainContent` is
    /// the already-loaded plain-text fallback.
    private func renderDetailContent(for event: StoredClipboardEvent, plainContent: String) {
        showPlainDetailSurface()
        detailTextView.font = event.contentType == .code
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .systemFont(ofSize: 15)

        guard let rich = event.richContent else {
            detailTextView.string = plainContent
            return
        }

        switch rich.kind {
        case ClipboardRichContent.imageKind:
            detailScrollView.isHidden = true
            detailImageView.isHidden = false
            if let cached = RichThumbnailProvider.shared.cachedThumbnail(forEventID: event.id) {
                detailImageView.image = cached
                return
            }
            let generation = richDetailGeneration
            richDetailPending = true
            RichThumbnailProvider.shared.thumbnail(for: event, reader: reader) { [weak self] image in
                guard let self, self.richDetailGeneration == generation else {
                    // Stale completion: leave `richDetailPending` alone — a
                    // newer render owns it (every new render resets it in
                    // showPlainDetailSurface()).
                    return
                }
                self.richDetailPending = false
                if let image {
                    self.detailImageView.image = image
                } else {
                    // Unreadable/undecodable body: fall back to text.
                    self.detailImageView.isHidden = true
                    self.detailScrollView.isHidden = false
                    self.detailTextView.string = event.contentPreview
                }
            }

        case ClipboardRichContent.rtfKind:
            if let data = try? reader.richBody(for: event),
               let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
                detailTextView.textStorage?.setAttributedString(attributed)
            } else {
                // Parse or read failure: the plain fallback is the content.
                detailTextView.string = plainContent
            }

        case ClipboardRichContent.fileListKind:
            detailTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            detailTextView.string = Self.fileListDetailText(
                files: reader.fileList(for: event),
                totalCount: event.richContent?.fileCount
            )

        case ClipboardRichContent.colorKind:
            let hex = rich.colorHex ?? ""
            let space = rich.colorSpace ?? "sRGB"
            detailScrollView.isHidden = true
            detailImageView.isHidden = false
            detailImageView.imageScaling = .scaleProportionallyUpOrDown
            detailImageView.image = RichThumbnailProvider.colorSwatch(
                hex: hex,
                colorSpace: space,
                fill: Self.swatchColor(fromHex: hex)
            )

        case ClipboardRichContent.linkKind:
            detailTextView.string = [rich.linkTitle, rich.linkURL]
                .compactMap { $0 }
                .joined(separator: "\n")

        default:
            // Unknown rich kind from a newer build: plain fallback.
            detailTextView.string = plainContent.isEmpty ? event.contentPreview : plainContent
        }
    }

    /// Monospaced name · size · path listing with "(missing)" annotations.
    private static func fileListDetailText(
        files: [ClipboardRichFileReference],
        totalCount: Int?
    ) -> String {
        guard !files.isEmpty else {
            return "No file entries recorded."
        }
        var lines = files.map { file -> String in
            var parts = [file.name]
            if let byteCount = file.byteCount {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
            }
            parts.append(file.path)
            var line = parts.joined(separator: " · ")
            if !FileManager.default.fileExists(atPath: file.path) {
                line += " (missing)"
            }
            return line
        }
        if let totalCount, totalCount > files.count {
            lines.append("… and \(totalCount - files.count) more (full list stored with the clip)")
        }
        return lines.joined(separator: "\n")
    }

    private static func swatchColor(fromHex hex: String) -> NSColor {
        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return .gray
        }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Friendly Format labels for the details row.
    private func formatLabel(for event: StoredClipboardEvent) -> String {
        if event.richContent?.kind == ClipboardRichContent.linkKind {
            return "Link"
        }
        switch event.contentType {
        case .image:
            if let width = event.richContent?.imagePixelWidth,
               let height = event.richContent?.imagePixelHeight {
                return "Image \(width)×\(height)"
            }
            return "Image"
        case .fileReference:
            return "Files"
        case .richText:
            return "Rich Text"
        case .color:
            return "Color"
        default:
            return event.contentType.rawValue.capitalized
        }
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

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
