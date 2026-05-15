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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard Archive Settings"
        window.minSize = NSSize(width: 700, height: 560)
        super.init(window: window)
        buildUI()
        loadSettingsIntoControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(settings: ClipboardSettings) {
        self.settings = settings
        loadSettingsIntoControls()
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
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let captureGroup = addGroup("Capture", to: root)
        archiveEnabledButton.target = self
        archiveEnabledButton.action = #selector(toggleArchiveEnabled)
        captureGroup.addArrangedSubview(archiveEnabledButton)

        for mode in ClipboardRetentionMode.allCases {
            retentionModePopup.addItem(withTitle: mode.displayName)
            retentionModePopup.lastItem?.representedObject = mode.rawValue
        }
        retentionModePopup.target = self
        retentionModePopup.action = #selector(retentionModeChanged)
        captureGroup.addArrangedSubview(formRow(label: "Storage mode", control: retentionModePopup))

        let visibleGroup = addGroup("Visible History", to: root)
        let recentRow = formRow(label: "Items shown in clipboard window", control: recentLimitField)
        recentLimitField.alignment = .right
        recentLimitField.formatter = integerFormatter()
        recentLimitField.target = self
        recentLimitField.action = #selector(recentLimitChanged)
        recentLimitStepper.minValue = 5
        recentLimitStepper.maxValue = Double(ClipboardSettings.maximumRecentItemLimit)
        recentLimitStepper.increment = 50
        recentLimitStepper.target = self
        recentLimitStepper.action = #selector(recentStepperChanged)
        recentRow.addArrangedSubview(recentLimitStepper)
        visibleGroup.addArrangedSubview(recentRow)

        let pollingGroup = addGroup("Polling", to: root)
        pollIntervalField.alignment = .right
        pollIntervalField.formatter = decimalFormatter()
        pollingGroup.addArrangedSubview(formRow(label: "Poll interval seconds", control: pollIntervalField))

        let excludedGroup = addGroup("Excluded Apps", to: root)
        let helper = NSTextField(labelWithString: "Use macOS bundle identifiers, not app names. Example: com.apple.Safari")
        helper.textColor = .secondaryLabelColor
        helper.lineBreakMode = .byWordWrapping
        excludedGroup.addArrangedSubview(helper)

        let addRow = NSStackView()
        addRow.orientation = .horizontal
        addRow.spacing = 8
        addRow.alignment = .centerY
        excludedBundleField.placeholderString = "com.apple.Safari"
        excludedBundleField.target = self
        excludedBundleField.action = #selector(addExcludedBundle)
        excludedBundleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addRow.addArrangedSubview(excludedBundleField)
        addRow.addArrangedSubview(NSButton(title: "Add", target: self, action: #selector(addExcludedBundle)))
        addRow.addArrangedSubview(NSButton(title: "Remove Selected", target: self, action: #selector(removeSelectedExcludedBundle)))
        excludedGroup.addArrangedSubview(addRow)

        let excludedScroll = NSScrollView()
        excludedScroll.hasVerticalScroller = true
        excludedScroll.borderType = .bezelBorder
        excludedBundlesList.headerView = nil
        excludedBundlesList.rowHeight = 24
        excludedBundlesList.usesAlternatingRowBackgroundColors = true
        excludedBundlesList.dataSource = self
        excludedBundlesList.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        column.resizingMask = .autoresizingMask
        excludedBundlesList.addTableColumn(column)
        excludedScroll.documentView = excludedBundlesList
        excludedScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        excludedGroup.addArrangedSubview(excludedScroll)

        let storageGroup = addGroup("Storage", to: root)
        storageGroup.addArrangedSubview(pathRow("Archive", archiveRoot.path))
        storageGroup.addArrangedSubview(pathRow("Settings", settingsStore.settingsURL.path))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        buttons.addArrangedSubview(statusLabel)
        buttons.addArrangedSubview(NSView())
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(saveButton)
        root.addArrangedSubview(buttons)
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

    @objc private func save() {
        let poll = max(0.1, min(5.0, pollIntervalField.doubleValue))
        let mode = selectedRetentionMode()
        let limit = mode.retainedItemLimit ?? ClipboardSettings.clampRecentItemLimit(recentLimitField.integerValue)
        settings.archiveEnabled = archiveEnabledButton.state == .on
        settings.retentionMode = mode
        settings.recentItemLimit = limit
        settings.pollIntervalSeconds = poll
        settings.excludedBundleIdentifiers = Array(Set(excludedBundleIdentifiers)).sorted()

        do {
            try settingsStore.save(settings)
            delegate?.clipboardSettingsWindow(self, didSave: settings)
            statusLabel.stringValue = "Saved"
            window?.orderOut(nil)
        } catch {
            statusLabel.stringValue = "Save failed"
        }
    }

    private func addGroup(_ title: String, to root: NSStackView) -> NSStackView {
        let box = NSBox()
        box.title = title
        box.boxType = .primary
        box.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        box.contentView?.addSubview(stack)
        if let contentView = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        root.addArrangedSubview(box)
        return stack
    }

    private func formRow(label: String, control: NSControl) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.textColor = .secondaryLabelColor
        text.widthAnchor.constraint(equalToConstant: 170).isActive = true
        control.widthAnchor.constraint(equalToConstant: control is NSPopUpButton ? 180 : 92).isActive = true
        row.addArrangedSubview(text)
        row.addArrangedSubview(control)
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

    private func pathRow(_ label: String, _ path: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let title = NSTextField(labelWithString: label)
        title.alignment = .right
        title.textColor = .secondaryLabelColor
        title.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let text = NSTextField(labelWithString: path)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingMiddle
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(title)
        row.addArrangedSubview(text)
        return row
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
