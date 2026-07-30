import ClipboardArchiveCore
import AppKit
import Foundation

/// Bulk Cleanup sheet (Slice 5, contracts 5/6). Criteria popups feed ONE
/// engine path; Preview shows the truthful dry-run numbers; Delete stays
/// disabled until a preview matches the CURRENT criteria (any edit
/// invalidates); "Include pinned" fires its own confirmation quoting the
/// preview's exempted-pinned count; execution runs on a background queue
/// and the completion refreshes History through the app's archive-mutation
/// hook.
@MainActor
final class ClipboardBulkSheetController: NSObject {
    private let archiveRoot: URL
    private let engine: ClipboardBulkEngine
    private let onExecuted: (ClipboardBulkResult) -> Void

    let sheetWindow: NSWindow

    private let datePopup = NSPopUpButton()
    private let appPopup = NSPopUpButton()
    private let typePopup = NSPopUpButton()
    private let sensitivityPopup = NSPopUpButton()
    private let includePinnedCheckbox = NSButton(
        checkboxWithTitle: "Include pinned clips",
        target: nil,
        action: nil
    )
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let resultLabel = NSTextField(wrappingLabelWithString: " ")
    private let workQueue = DispatchQueue(label: "app.clipboardarchive.bulk-sheet")
    private var workInFlight = false

    /// Preview validity: the criteria snapshot the last preview ran
    /// against. Delete is enabled only while the current criteria equal it.
    private var previewedCriteria: ClipboardBulkCriteria?
    private var lastPreview: ClipboardBulkResult?

    private static let dateChoices: [(title: String, days: Int?)] = [
        ("Any age", nil),
        ("Older than 7 days", 7),
        ("Older than 30 days", 30),
        ("Older than 90 days", 90),
        ("Older than 1 year", 365)
    ]
    private static let typeChoices: [(title: String, raw: String?)] = [
        ("Any type", nil),
        ("Text", "text"),
        ("Links", "url"),
        ("Code", "code")
    ]
    private static let sensitivityChoices: [(title: String, value: ClipboardBulkCriteria.Sensitivity?)] = [
        ("Any sensitivity", nil),
        ("Flagged sensitive", .anyFlagged),
        ("Manually restricted", .manualRestricted)
    ]
    private static let anyAppTitle = "Any app"

    init(
        archiveRoot: URL,
        onExecuted: @escaping (ClipboardBulkResult) -> Void
    ) {
        self.archiveRoot = archiveRoot
        self.engine = ClipboardBulkEngine(archiveRoot: archiveRoot)
        self.onExecuted = onExecuted
        self.sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        sheetWindow.title = "Bulk Cleanup"
        buildUI()
        populateAppPopup()
    }

    private func buildUI() {
        guard let contentView = sheetWindow.contentView else {
            return
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "Bulk Cleanup")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: "Deletes every clip matching ALL selected filters. Preview shows the exact impact; deletion cannot be undone."
        )
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)

        for choice in Self.dateChoices {
            datePopup.addItem(withTitle: choice.title)
        }
        appPopup.addItem(withTitle: Self.anyAppTitle)
        for choice in Self.typeChoices {
            typePopup.addItem(withTitle: choice.title)
        }
        for choice in Self.sensitivityChoices {
            sensitivityPopup.addItem(withTitle: choice.title)
        }
        for popup in [datePopup, appPopup, typePopup, sensitivityPopup] {
            popup.target = self
            popup.action = #selector(criteriaChanged)
        }
        datePopup.setAccessibilityLabel("Bulk cleanup age filter")
        appPopup.setAccessibilityLabel("Bulk cleanup app filter")
        typePopup.setAccessibilityLabel("Bulk cleanup type filter")
        sensitivityPopup.setAccessibilityLabel("Bulk cleanup sensitivity filter")

        let criteriaRow = NSStackView(views: [datePopup, appPopup])
        criteriaRow.orientation = .horizontal
        criteriaRow.spacing = 9
        let criteriaRowTwo = NSStackView(views: [typePopup, sensitivityPopup])
        criteriaRowTwo.orientation = .horizontal
        criteriaRowTwo.spacing = 9
        stack.addArrangedSubview(criteriaRow)
        stack.addArrangedSubview(criteriaRowTwo)

        includePinnedCheckbox.target = self
        includePinnedCheckbox.action = #selector(includePinnedToggled)
        includePinnedCheckbox.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(includePinnedCheckbox)

        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.stringValue = "Choose filters, then Preview."
        stack.addArrangedSubview(resultLabel)
        resultLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        previewButton.target = self
        previewButton.action = #selector(previewClicked)
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isEnabled = false
        closeButton.title = "Close"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        let buttons = NSStackView(views: [closeButton, NSView(), previewButton, deleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 9
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    private func populateAppPopup() {
        let index = ClipboardDerivedIndex(archiveRoot: archiveRoot)
        workQueue.async { @Sendable [weak self] in
            let apps = (try? index.distinctSourceApps()) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else {
                        return
                    }
                    let selected = self.appPopup.titleOfSelectedItem
                    self.appPopup.removeAllItems()
                    self.appPopup.addItem(withTitle: Self.anyAppTitle)
                    self.appPopup.addItems(withTitles: apps)
                    if let selected, self.appPopup.itemTitles.contains(selected) {
                        self.appPopup.selectItem(withTitle: selected)
                    }
                }
            }
        }
    }

    // MARK: - Criteria

    private func currentCriteria() -> ClipboardBulkCriteria {
        var criteria = ClipboardBulkCriteria()
        if let days = Self.dateChoices[max(0, datePopup.indexOfSelectedItem)].days {
            criteria.until = Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }
        if let app = appPopup.titleOfSelectedItem, app != Self.anyAppTitle {
            criteria.sourceAppName = app
        }
        criteria.contentType = Self.typeChoices[max(0, typePopup.indexOfSelectedItem)].raw
        criteria.sensitivity = Self.sensitivityChoices[max(0, sensitivityPopup.indexOfSelectedItem)].value
        criteria.includePinned = includePinnedCheckbox.state == .on
        return criteria
    }

    /// Comparable criteria signature: `until` re-derives from "now" every
    /// call, so comparing Dates directly would always invalidate. Compare
    /// the POPUP selections plus modifier state instead.
    private struct CriteriaSignature: Equatable {
        var dateIndex: Int
        var appTitle: String?
        var typeIndex: Int
        var sensitivityIndex: Int
        var includePinned: Bool
    }

    private func currentSignature() -> CriteriaSignature {
        CriteriaSignature(
            dateIndex: datePopup.indexOfSelectedItem,
            appTitle: appPopup.titleOfSelectedItem,
            typeIndex: typePopup.indexOfSelectedItem,
            sensitivityIndex: sensitivityPopup.indexOfSelectedItem,
            includePinned: includePinnedCheckbox.state == .on
        )
    }

    private var previewedSignature: CriteriaSignature?

    @objc private func criteriaChanged() {
        invalidatePreview(message: "Criteria changed — preview again before deleting.")
    }

    private func invalidatePreview(message: String) {
        previewedSignature = nil
        previewedCriteria = nil
        lastPreview = nil
        deleteButton.isEnabled = false
        resultLabel.stringValue = message
    }

    @objc private func includePinnedToggled() {
        guard includePinnedCheckbox.state == .on else {
            criteriaChanged()
            return
        }
        // Contract 5: including pinned content is a SEPARATE confirmation,
        // quoting the exempted-pinned count from the last preview when one
        // exists.
        let alert = NSAlert()
        alert.messageText = "Also delete pinned clips?"
        if let preview = lastPreview, preview.exemptedPinnedEvents > 0 {
            alert.informativeText = "The last preview kept \(preview.exemptedPinnedEvents) pinned clip\(preview.exemptedPinnedEvents == 1 ? "" : "s"). Pins normally protect clips from every cleanup."
        } else {
            alert.informativeText = "Pins normally protect clips from every cleanup. With this on, matching pinned clips are deleted too."
        }
        alert.addButton(withTitle: "Include Pinned")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if !automationBypassesAlerts, alert.runModal() != .alertFirstButtonReturn {
            includePinnedCheckbox.state = .off
            return
        }
        criteriaChanged()
    }

    // MARK: - Preview / execute (ONE engine path)

    @objc private func previewClicked() {
        let criteria = currentCriteria()
        guard !criteria.isEmpty else {
            resultLabel.stringValue = "Choose at least one filter first — an unfiltered bulk delete would erase the whole archive."
            return
        }
        guard !workInFlight else {
            return
        }
        workInFlight = true
        let signature = currentSignature()
        resultLabel.stringValue = "Previewing…"
        let engine = engine
        runWork { @Sendable in
            try? engine.preview(criteria)
        } completion: { [weak self] preview in
            guard let self else {
                return
            }
            self.workInFlight = false
            guard let preview else {
                self.resultLabel.stringValue = "Preview failed."
                return
            }
            self.lastPreview = preview
            self.previewedCriteria = criteria
            self.previewedSignature = signature
            var text = "Would delete \(preview.matchedEvents) clip\(preview.matchedEvents == 1 ? "" : "s"), reclaiming \(Self.bytes(preview.reclaimedBytes))."
            if preview.exemptedPinnedEvents > 0 {
                text += " \(preview.exemptedPinnedEvents) pinned clip\(preview.exemptedPinnedEvents == 1 ? "" : "s") will be kept — check \"Include pinned clips\" to delete them too."
            }
            self.resultLabel.stringValue = text
            self.deleteButton.isEnabled = preview.matchedEvents > 0
        }
    }

    @objc private func deleteClicked() {
        guard previewedSignature == currentSignature(),
              let criteria = previewedCriteria,
              let preview = lastPreview else {
            invalidatePreview(message: "Preview again before deleting.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(preview.matchedEvents) clip\(preview.matchedEvents == 1 ? "" : "s")?"
        alert.informativeText = "Reclaims about \(Self.bytes(preview.reclaimedBytes)). This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if !automationBypassesAlerts, alert.runModal() != .alertFirstButtonReturn {
            return
        }
        guard !workInFlight else {
            return
        }
        workInFlight = true
        deleteButton.isEnabled = false
        closeButton.isEnabled = false
        resultLabel.stringValue = "Deleting…"
        let engine = engine
        // Deliberate STRONG self capture: the deletion mutates the archive,
        // and closing the sheet mid-run must not deallocate the controller
        // before `onExecuted` fires — that would leave the History window
        // and quick-picker caches referencing already-redacted events.
        runWork { @Sendable in
            try? engine.execute(criteria)
        } completion: { result in
            self.workInFlight = false
            self.closeButton.isEnabled = true
            self.previewedSignature = nil
            self.previewedCriteria = nil
            self.lastPreview = nil
            guard let result else {
                self.resultLabel.stringValue = "Deletion failed."
                return
            }
            self.lastExecuted = result
            self.resultLabel.stringValue = "Deleted \(result.matchedEvents) clip\(result.matchedEvents == 1 ? "" : "s"), reclaimed \(Self.bytes(result.reclaimedBytes))."
            self.onExecuted(result)
        }
    }

    /// Background execution with a synchronous DEBUG-automation escape
    /// hatch so harness receipts are deterministic.
    private func runWork(
        _ work: @escaping @Sendable () -> ClipboardBulkResult?,
        completion: @escaping @MainActor @Sendable (ClipboardBulkResult?) -> Void
    ) {
        if automationBypassesAlerts {
            completion(work())
            return
        }
        workQueue.async { @Sendable in
            let result = work()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(result)
                }
            }
        }
    }

    @objc private func closeClicked() {
        sheetWindow.sheetParent?.endSheet(sheetWindow)
    }

    private var automationBypassesAlerts: Bool {
#if DEBUG
        return ProcessInfo.processInfo.environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN"] != nil
#else
        return false
#endif
    }

    private var lastExecuted: ClipboardBulkResult?

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

#if DEBUG
    var automationLastPreview: ClipboardBulkResult? {
        lastPreview
    }

    var automationLastExecuted: ClipboardBulkResult? {
        lastExecuted
    }

    var automationDeleteEnabled: Bool {
        deleteButton.isEnabled
    }

    var automationResultText: String {
        resultLabel.stringValue
    }

    func performAutomationDateChoice(_ index: Int) {
        datePopup.selectItem(at: index)
        criteriaChanged()
    }

    func performAutomationTypeChoice(_ index: Int) {
        typePopup.selectItem(at: index)
        criteriaChanged()
    }

    func performAutomationIncludePinned(_ include: Bool) {
        includePinnedCheckbox.state = include ? .on : .off
        includePinnedToggled()
    }

    func performAutomationPreview() {
        previewClicked()
    }

    func performAutomationDelete() {
        deleteClicked()
    }

    func writeSnapshot(to url: URL) throws {
        guard let view = sheetWindow.contentView else {
            return
        }
        // A sheet driven synchronously by automation may never have gone
        // through a normal on-screen display pass; order it in (without
        // activating anything) and force layout so the bitmap is not blank.
        if !sheetWindow.isVisible {
            sheetWindow.orderFrontRegardless()
        }
        sheetWindow.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        sheetWindow.display()
        // cacheDisplay renders blank for this never-presented window, so
        // rasterize its PDF representation instead.
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return
        }
        let pdfData = view.dataWithPDF(inside: bounds)
        guard let pdfImage = NSImage(data: pdfData) else {
            return
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width),
            pixelsHigh: Int(bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        pdfImage.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try data.write(to: url, options: [.atomic])
    }
#endif
}
