import ClipboardArchiveCore
import AppKit
import Foundation

@MainActor
protocol ClipboardSettingsWindowControllerDelegate: AnyObject {
    func clipboardSettingsWindow(_ controller: ClipboardSettingsWindowController, didSave settings: ClipboardSettings)
}

@MainActor
final class ClipboardSettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: ClipboardSettingsWindowControllerDelegate?

    private let settingsStore: ClipboardSettingsStore
    private let archiveRoot: URL
    private var settings: ClipboardSettings

    private let archiveEnabledButton = NSButton(checkboxWithTitle: "Capture clipboard history", target: nil, action: nil)
    private let retentionModePopup = NSPopUpButton()
    private let historyWindowPopup = NSPopUpButton()
    private let recentLimitField = NSTextField()
    private let recentLimitStepper = NSStepper()
    private let pollIntervalField = NSTextField()
    private let excludedBundleField = NSTextField()
    private let excludedBundlesList = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var excludedBundleIdentifiers: [String] = []

    init(settings: ClipboardSettings, settingsStore: ClipboardSettingsStore, archiveRoot: URL) {
        self.settings = settings
        self.settingsStore = settingsStore
        self.archiveRoot = archiveRoot

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Archive Settings"
        window.minSize = NSSize(width: 760, height: 560)
        window.setFrameAutosaveName("ClipboardSettingsWindowV2")
        super.init(window: window)
        buildUI()
        loadSettingsIntoControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(settings: ClipboardSettings, activate: Bool = true) {
        self.settings = settings
        loadSettingsIntoControls()
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
#endif

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        configureGeneralControls()
        configurePrivacyControls()

        let header = brandedHeader()
        let footer = actionFooter()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 18
        columns.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(columns)

        let captureCard = sectionCard(
            title: "Capture & Retention",
            subtitle: "Control what Clipboard Archive remembers and how long stored content remains.",
            symbol: "doc.on.clipboard.fill",
            tint: .systemBlue,
            views: [
                archiveEnabledButton,
                separatorView(),
                settingRow(
                    title: "Archive retention",
                    detail: "Older content is pruned automatically in limited modes.",
                    control: retentionModePopup
                ),
                settingRow(
                    title: "Capture frequency",
                    detail: "Lower values notice copies sooner.",
                    control: intervalControl()
                )
            ]
        )

        let historyCard = sectionCard(
            title: "History Window",
            subtitle: "Choose the timeline shown in History. This changes the working view, not your archive.",
            symbol: "clock.arrow.circlepath",
            tint: .systemPurple,
            views: [
                settingRow(
                    title: "Show clips from",
                    detail: "Adjust the timeline available for browsing and filtering.",
                    control: historyWindowPopup
                ),
                settingRow(
                    title: "Maximum clips loaded",
                    detail: "Limits memory use when opening History.",
                    control: recentLimitControl()
                )
            ]
        )

        let privacyCard = sectionCard(
            title: "Private App Exclusions",
            subtitle: "Password managers are blocked automatically. Add any other app by bundle identifier.",
            symbol: "hand.raised.fill",
            tint: .systemRed,
            views: privacyControls()
        )

        let storageCard = sectionCard(
            title: "Local Storage",
            subtitle: "Accepted clips and the search index stay on this Mac in owner-only files.",
            symbol: "internaldrive.fill",
            tint: .systemGreen,
            views: [storageControls()]
        )

        let leftColumn = NSStackView()
        leftColumn.orientation = .vertical
        leftColumn.alignment = .width
        leftColumn.spacing = 18
        leftColumn.addArrangedSubview(captureCard)
        leftColumn.addArrangedSubview(historyCard)

        let rightColumn = NSStackView()
        rightColumn.orientation = .vertical
        rightColumn.alignment = .width
        rightColumn.spacing = 18
        rightColumn.addArrangedSubview(privacyCard)
        rightColumn.addArrangedSubview(storageCard)

        columns.addArrangedSubview(leftColumn)
        columns.addArrangedSubview(rightColumn)

        header.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(header)
        contentView.addSubview(scroll)
        contentView.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 112),

            scroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            columns.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            columns.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            columns.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            columns.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
    }

    private func brandedHeader() -> NSView {
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.09)
            .cgColor

        let mark = iconTile(
            symbol: "doc.on.clipboard.fill",
            tint: .systemBlue,
            size: 54
        )

        let eyebrow = NSTextField(labelWithString: "SETTINGS")
        eyebrow.font = .systemFont(ofSize: 10, weight: .bold)
        eyebrow.textColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Clipboard Archive")
        title.font = .systemFont(ofSize: 23, weight: .bold)
        let subtitle = NSTextField(
            labelWithString: "Shape your local clipboard memory, timeline, and privacy boundaries."
        )
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let text = NSStackView(views: [eyebrow, title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let version = NSTextField(labelWithString: versionText())
        version.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        version.textColor = .secondaryLabelColor
        version.drawsBackground = true
        version.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.75)
        version.isBezeled = false
        version.isEditable = false
        version.alignment = .center
        version.wantsLayer = true
        version.layer?.cornerRadius = 8
        version.widthAnchor.constraint(greaterThanOrEqualToConstant: 124).isActive = true
        version.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(mark)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(version)
        header.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 28),
            row.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -28),
            row.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    private func actionFooter() -> NSView {
        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let separator = separatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(separator)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 9
        buttons.alignment = .centerY
        buttons.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        buttons.addArrangedSubview(statusLabel)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(NSButton(title: "Cancel", target: self, action: #selector(cancel)))
        let saveButton = NSButton(title: "Save Changes", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.contentTintColor = .controlAccentColor
        buttons.addArrangedSubview(saveButton)
        footer.addSubview(buttons)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            buttons.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 28),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -28),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        return footer
    }

    private func configureGeneralControls() {
        archiveEnabledButton.target = self
        archiveEnabledButton.action = #selector(toggleArchiveEnabled)
        archiveEnabledButton.font = .systemFont(ofSize: 13, weight: .medium)
        for mode in ClipboardRetentionMode.allCases {
            retentionModePopup.addItem(withTitle: mode.displayName)
            retentionModePopup.lastItem?.representedObject = mode.rawValue
        }
        retentionModePopup.target = self
        retentionModePopup.action = #selector(retentionModeChanged)
        retentionModePopup.setAccessibilityLabel("Archive retention")
        for historyWindow in ClipboardHistoryWindow.allCases {
            historyWindowPopup.addItem(withTitle: historyWindow.displayName)
            historyWindowPopup.lastItem?.representedObject = historyWindow.rawValue
        }
        historyWindowPopup.setAccessibilityLabel("History time range")
        recentLimitField.alignment = .right
        recentLimitField.formatter = integerFormatter()
        recentLimitField.target = self
        recentLimitField.action = #selector(recentLimitChanged)
        recentLimitField.setAccessibilityLabel("Maximum clips loaded")
        recentLimitStepper.minValue = 5
        recentLimitStepper.maxValue = Double(ClipboardSettings.maximumRecentItemLimit)
        recentLimitStepper.increment = 50
        recentLimitStepper.target = self
        recentLimitStepper.action = #selector(recentStepperChanged)
        pollIntervalField.alignment = .right
        pollIntervalField.formatter = decimalFormatter()
        pollIntervalField.setAccessibilityLabel("Capture frequency in seconds")
    }

    private func configurePrivacyControls() {
        excludedBundleField.placeholderString = "com.example.sensitive-app"
        excludedBundleField.target = self
        excludedBundleField.action = #selector(addExcludedBundle)
        excludedBundleField.setAccessibilityLabel("App bundle identifier to exclude")
        excludedBundlesList.headerView = nil
        excludedBundlesList.rowHeight = 28
        excludedBundlesList.usesAlternatingRowBackgroundColors = true
        excludedBundlesList.dataSource = self
        excludedBundlesList.delegate = self
        excludedBundlesList.setAccessibilityLabel("Excluded applications")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        column.resizingMask = .autoresizingMask
        excludedBundlesList.addTableColumn(column)
        excludedBundlesList.autoresizingMask = [.width]
    }

    private func privacyControls() -> [NSView] {
        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.spacing = 7
        addRow.alignment = .centerY
        addRow.addArrangedSubview(excludedBundleField)
        let addButton = NSButton(title: "Add App", target: self, action: #selector(addExcludedBundle))
        addRow.addArrangedSubview(addButton)

        let excludedScroll = NSScrollView()
        excludedScroll.hasVerticalScroller = true
        excludedScroll.borderType = .bezelBorder
        excludedBundlesList.frame = excludedScroll.contentView.bounds
        excludedScroll.documentView = excludedBundlesList
        excludedScroll.heightAnchor.constraint(equalToConstant: 128).isActive = true

        let remove = NSButton(
            title: "Remove Selected",
            target: self,
            action: #selector(removeSelectedExcludedBundle)
        )
        remove.alignment = .left
        return [addRow, excludedScroll, remove]
    }

    private func sectionCard(
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
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSStackView()
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 11
        let headingIcon = iconTile(symbol: symbol, tint: tint, size: 38)
        let headingText = NSStackView()
        headingText.orientation = .vertical
        headingText.alignment = .leading
        headingText.spacing = 3
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitleLabel = wrappingLabel(subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        headingText.addArrangedSubview(titleLabel)
        headingText.addArrangedSubview(subtitleLabel)
        heading.addArrangedSubview(headingIcon)
        heading.addArrangedSubview(headingText)
        stack.addArrangedSubview(heading)
        for view in views {
            stack.addArrangedSubview(view)
        }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return card
    }

    private func settingRow(title: String, detail: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let detailLabel = wrappingLabel(detail)
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .tertiaryLabelColor
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(labels)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(control)
        return row
    }

    private func recentLimitControl() -> NSView {
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5
        recentLimitField.widthAnchor.constraint(equalToConstant: 68).isActive = true
        controls.addArrangedSubview(recentLimitField)
        controls.addArrangedSubview(recentLimitStepper)
        return controls
    }

    private func intervalControl() -> NSView {
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6
        pollIntervalField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let seconds = NSTextField(labelWithString: "sec")
        seconds.font = .systemFont(ofSize: 11)
        seconds.textColor = .secondaryLabelColor
        controls.addArrangedSubview(pollIntervalField)
        controls.addArrangedSubview(seconds)
        return controls
    }

    private func storageControls() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9

        let privacy = NSStackView()
        privacy.orientation = .horizontal
        privacy.alignment = .centerY
        privacy.spacing = 7
        let lock = NSImageView()
        lock.image = NSImage(
            systemSymbolName: "lock.fill",
            accessibilityDescription: "Owner-only local storage"
        )
        lock.contentTintColor = .systemGreen
        let privacyText = NSTextField(labelWithString: "Owner-only files · no cloud sync")
        privacyText.font = .systemFont(ofSize: 11, weight: .medium)
        privacy.addArrangedSubview(lock)
        privacy.addArrangedSubview(privacyText)

        let path = wrappingLabel(archiveRoot.path)
        path.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        path.textColor = .tertiaryLabelColor
        let reveal = NSButton(
            title: "Show Archive in Finder",
            target: self,
            action: #selector(showArchiveInFinder)
        )
        stack.addArrangedSubview(privacy)
        stack.addArrangedSubview(path)
        stack.addArrangedSubview(reveal)
        return stack
    }

    private func iconTile(symbol: String, tint: NSColor, size: CGFloat) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = tint.cgColor
        tile.layer?.cornerRadius = size * 0.24
        tile.translatesAutoresizingMaskIntoConstraints = false

        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: nil
        )
        image.contentTintColor = .white
        image.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: size * 0.42,
            weight: .semibold
        )
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        return tile
    }

    private func separatorView() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func versionText() -> String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else {
            return "Development build"
        }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    private func loadSettingsIntoControls() {
        archiveEnabledButton.state = settings.archiveEnabled ? .on : .off
        selectRetentionMode(settings.retentionMode)
        selectHistoryWindow(settings.historyWindow)
        recentLimitField.integerValue = settings.recentItemLimit
        recentLimitStepper.integerValue = settings.recentItemLimit
        pollIntervalField.doubleValue = settings.pollIntervalSeconds
        excludedBundleIdentifiers = settings.excludedBundleIdentifiers.sorted()
        excludedBundleField.stringValue = ""
        excludedBundlesList.reloadData()
        updateRetentionStatus()
    }

    @objc private func toggleArchiveEnabled() {
        updateRetentionStatus()
    }

    @objc private func retentionModeChanged() {
        let mode = selectedRetentionMode()
        if let limit = mode.retainedItemLimit {
            recentLimitField.integerValue = limit
            recentLimitStepper.integerValue = limit
        }
        updateRetentionStatus()
    }

    @objc private func recentStepperChanged() {
        recentLimitField.integerValue = recentLimitStepper.integerValue
    }

    @objc private func recentLimitChanged() {
        let value = ClipboardSettings.clampRecentItemLimit(recentLimitField.integerValue)
        recentLimitField.integerValue = value
        recentLimitStepper.integerValue = value
    }

    @objc private func addExcludedBundle() {
        let value = excludedBundleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }
        if !excludedBundleIdentifiers.contains(value) {
            excludedBundleIdentifiers.append(value)
            excludedBundleIdentifiers.sort()
            excludedBundlesList.reloadData()
        }
        excludedBundleField.stringValue = ""
        statusLabel.stringValue = "Added exclusion"
    }

    @objc private func removeSelectedExcludedBundle() {
        let row = excludedBundlesList.selectedRow
        guard row >= 0, row < excludedBundleIdentifiers.count else {
            return
        }
        excludedBundleIdentifiers.remove(at: row)
        excludedBundlesList.reloadData()
        statusLabel.stringValue = "Removed exclusion"
    }

    @objc private func cancel() {
        window?.orderOut(nil)
    }

    @objc private func showArchiveInFinder() {
        NSWorkspace.shared.open(archiveRoot)
    }

    @objc private func save() {
        let poll = max(0.1, min(5.0, pollIntervalField.doubleValue))
        let mode = selectedRetentionMode()
        let limit = mode.retainedItemLimit ?? ClipboardSettings.clampRecentItemLimit(recentLimitField.integerValue)
        settings.archiveEnabled = archiveEnabledButton.state == .on
        settings.retentionMode = mode
        settings.recentItemLimit = limit
        settings.historyWindow = selectedHistoryWindow()
        settings.pollIntervalSeconds = poll
        settings.excludedBundleIdentifiers = Array(Set(excludedBundleIdentifiers)).sorted()
        settings.hasCompletedOnboarding = true

        do {
            try settingsStore.save(settings)
            delegate?.clipboardSettingsWindow(self, didSave: settings)
            statusLabel.stringValue = "Saved"
            window?.orderOut(nil)
        } catch {
            statusLabel.stringValue = "Save failed"
        }
    }

    private func selectedRetentionMode() -> ClipboardRetentionMode {
        guard let rawValue = retentionModePopup.selectedItem?.representedObject as? String,
              let mode = ClipboardRetentionMode(rawValue: rawValue) else {
            return .unlimited
        }
        return mode
    }

    private func selectRetentionMode(_ mode: ClipboardRetentionMode) {
        for item in retentionModePopup.itemArray where item.representedObject as? String == mode.rawValue {
            retentionModePopup.select(item)
            return
        }
        retentionModePopup.selectItem(at: ClipboardRetentionMode.allCases.firstIndex(of: .unlimited) ?? 0)
    }

    private func selectedHistoryWindow() -> ClipboardHistoryWindow {
        guard let rawValue = historyWindowPopup.selectedItem?.representedObject as? Int,
              let historyWindow = ClipboardHistoryWindow(rawValue: rawValue) else {
            return .sevenDays
        }
        return historyWindow
    }

    private func selectHistoryWindow(_ historyWindow: ClipboardHistoryWindow) {
        for item in historyWindowPopup.itemArray
            where item.representedObject as? Int == historyWindow.rawValue {
            historyWindowPopup.select(item)
            return
        }
        historyWindowPopup.selectItem(at: 1)
    }

    private func updateRetentionStatus() {
        guard archiveEnabledButton.state == .on else {
            statusLabel.stringValue = "Capture will be off"
            return
        }
        let mode = selectedRetentionMode()
        statusLabel.stringValue = mode.storesLongTermHistory ? "Full long-term archive will be on" : "\(mode.displayName) will prune older content"
    }

    private func wrappingLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: ClipboardSettings.minimumRecentItemLimit)
        formatter.maximum = NSNumber(value: ClipboardSettings.maximumRecentItemLimit)
        return formatter
    }

    private func decimalFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0.1
        formatter.maximum = 5.0
        formatter.maximumFractionDigits = 2
        return formatter
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        excludedBundleIdentifiers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < excludedBundleIdentifiers.count else {
            return nil
        }
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: excludedBundleIdentifiers[row])
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
