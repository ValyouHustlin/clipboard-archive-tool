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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Archive"
        window.minSize = NSSize(width: 680, height: 520)
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

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let headingText = NSStackView()
        headingText.orientation = .vertical
        headingText.spacing = 3
        let title = NSTextField(labelWithString: "Clipboard Archive")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Choose what gets remembered—and what never should.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        headingText.addArrangedSubview(title)
        headingText.addArrangedSubview(subtitle)
        root.addArrangedSubview(headingText)

        configureGeneralControls()
        configurePrivacyControls()

        let columns = NSStackView()
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 14

        let generalColumn = NSStackView()
        generalColumn.orientation = .vertical
        generalColumn.spacing = 14
        generalColumn.addArrangedSubview(
            sectionCard(
                title: "Remember Clipboard Text",
                subtitle: "Accepted text stays on this Mac. Pause anytime from the menu bar.",
                views: [
                    archiveEnabledButton,
                    formRow(label: "Keep", control: retentionModePopup),
                    formRow(label: "Clips loaded", control: recentLimitField, trailing: recentLimitStepper)
                ]
            )
        )
        generalColumn.addArrangedSubview(
            sectionCard(
                title: "Capture Timing",
                subtitle: "Lower values notice new copies sooner but wake the app more often.",
                views: [
                    formRow(label: "Check every", control: pollIntervalField, suffix: "seconds")
                ]
            )
        )

        let privacyViews = privacyControls()
        let privacyCard = sectionCard(
            title: "Never Capture From These Apps",
            subtitle: "Password managers are blocked automatically. Add other sensitive apps by bundle identifier.",
            views: privacyViews
        )
        columns.addArrangedSubview(generalColumn)
        columns.addArrangedSubview(privacyCard)
        root.addArrangedSubview(columns)

        let storage = NSStackView()
        storage.orientation = .horizontal
        storage.spacing = 8
        storage.alignment = .centerY
        let localLabel = NSTextField(labelWithString: "Stored locally")
        localLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let path = NSTextField(labelWithString: "Everything stays in your local archive.")
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        storage.addArrangedSubview(localLabel)
        storage.addArrangedSubview(path)
        storage.addArrangedSubview(
            NSButton(title: "Show in Finder", target: self, action: #selector(showArchiveInFinder))
        )
        root.addArrangedSubview(storage)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        buttons.addArrangedSubview(statusLabel)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(NSButton(title: "Cancel", target: self, action: #selector(cancel)))
        let saveButton = NSButton(title: "Save Changes", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(saveButton)
        root.addArrangedSubview(buttons)
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
        recentLimitField.alignment = .right
        recentLimitField.formatter = integerFormatter()
        recentLimitField.target = self
        recentLimitField.action = #selector(recentLimitChanged)
        recentLimitStepper.minValue = 5
        recentLimitStepper.maxValue = Double(ClipboardSettings.maximumRecentItemLimit)
        recentLimitStepper.increment = 50
        recentLimitStepper.target = self
        recentLimitStepper.action = #selector(recentStepperChanged)
        pollIntervalField.alignment = .right
        pollIntervalField.formatter = decimalFormatter()
    }

    private func configurePrivacyControls() {
        excludedBundleField.placeholderString = "com.example.sensitive-app"
        excludedBundleField.target = self
        excludedBundleField.action = #selector(addExcludedBundle)
        excludedBundlesList.headerView = nil
        excludedBundlesList.rowHeight = 28
        excludedBundlesList.usesAlternatingRowBackgroundColors = true
        excludedBundlesList.dataSource = self
        excludedBundlesList.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        column.resizingMask = .autoresizingMask
        excludedBundlesList.addTableColumn(column)
        excludedBundlesList.autoresizingMask = [.width]
    }

    private func privacyControls() -> [NSView] {
        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.spacing = 7
        addRow.addArrangedSubview(excludedBundleField)
        addRow.addArrangedSubview(
            NSButton(title: "Add", target: self, action: #selector(addExcludedBundle))
        )

        let excludedScroll = NSScrollView()
        excludedScroll.hasVerticalScroller = true
        excludedScroll.borderType = .bezelBorder
        excludedBundlesList.frame = excludedScroll.contentView.bounds
        excludedScroll.documentView = excludedBundlesList
        excludedScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let remove = NSButton(
            title: "Remove Selected",
            target: self,
            action: #selector(removeSelectedExcludedBundle)
        )
        remove.alignment = .left
        return [addRow, excludedScroll, remove]
    }

    private func sectionCard(title: String, subtitle: String, views: [NSView]) -> NSView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let subtitleLabel = wrappingLabel(subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        for view in views {
            stack.addArrangedSubview(view)
        }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func loadSettingsIntoControls() {
        archiveEnabledButton.state = settings.archiveEnabled ? .on : .off
        selectRetentionMode(settings.retentionMode)
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

    private func formRow(
        label: String,
        control: NSControl,
        trailing: NSView? = nil,
        suffix: String? = nil
    ) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .centerY
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.textColor = .secondaryLabelColor
        text.widthAnchor.constraint(equalToConstant: 82).isActive = true
        control.widthAnchor.constraint(equalToConstant: control is NSPopUpButton ? 150 : 70).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(control)
        if let trailing {
            row.addArrangedSubview(trailing)
        }
        if let suffix {
            let suffixLabel = NSTextField(labelWithString: suffix)
            suffixLabel.textColor = .secondaryLabelColor
            row.addArrangedSubview(suffixLabel)
        }
        row.addArrangedSubview(NSView())
        return row
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
