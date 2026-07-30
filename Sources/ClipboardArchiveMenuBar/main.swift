import ClipboardArchiveCore
import AppKit
import ApplicationServices
import Foundation

private let archiveRoot = ClipboardDefaults.archiveRoot()

@MainActor
final class ClipboardMenuBarApp: NSObject,
    NSApplicationDelegate,
    ClipboardOnboardingWindowControllerDelegate,
    ClipboardSettingsWindowControllerDelegate {
    private let userDefaults = ClipboardDefaults.userDefaultsSuiteName()
        .flatMap(UserDefaults.init(suiteName:))
        ?? UserDefaults.standard
    private let settingsStore = ClipboardSettingsStore()
    private var settings = ClipboardSettings()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var isPaused = false
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastContentHash: Int?
    /// The one pasteboard the app touches. In DEBUG UI automation this is
    /// swapped for a private named pasteboard so gestures never clobber the
    /// real clipboard; production always uses `NSPasteboard.general`.
    private var pasteboard = NSPasteboard.general
    private let archiveWriter = ClipboardArchiveWriter(archiveRoot: archiveRoot)
    private let derivedIndex = ClipboardDerivedIndex(archiveRoot: archiveRoot)
    private lazy var ingestor = ClipboardIngestor(
        filter: ClipboardPrivacyFilter(settings: settings),
        archiveWriter: archiveWriter,
        derivedIndex: derivedIndex
    )
    private let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
    private let redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
    private var capturedCount = 0
    private var blockedCount = 0
    /// In-memory estimate of live (unsuppressed) archive events, used so the
    /// common under-limit retention check does zero archive scanning. Seeded
    /// by the first `enforceRetentionLimit` scan, incremented on each store,
    /// and reset to nil (forcing one reseed scan) when retention settings
    /// change. Deletions leave it as a safe overestimate.
    private var liveEventCountEstimate: Int?
    private var capturesSinceRetentionScan = 0
    private static let retentionRescanInterval = 10
    /// Non-nil while the configured quick-picker shortcut failed to
    /// register (conflict or Carbon error). Drives the persistent menu
    /// warning and is pushed into Settings on creation.
    private var shortcutFailureMessage: String?
    private var lastStatus = "Ready"
    private var lastNonSelfApp = ClipboardSourceApp(name: "Unknown", bundleIdentifier: nil)
    private var panelController: ClipboardPanelController?
    private var settingsWindowController: ClipboardSettingsWindowController?
    private var onboardingWindowController: ClipboardOnboardingWindowController?
    private static let quickPickerHotKeyID: UInt32 = 1
    private let hotKeyManager = GlobalHotKeyManager()
    private var quickPickerController: QuickPickerPanelController?
    /// Warm event list for the quick picker. Invalidated (dirty flag) at
    /// every archive mutation — store, delete, prune, settings save — so
    /// repeat opens are O(1) and a cold open does one `recentItems` scan.
    private var quickPickerCache: [StoredClipboardEvent] = []
    private var quickPickerCacheDirty = true
#if DEBUG
    /// True when the DEBUG UI automation harness drives this instance.
    /// Automation NEVER registers the Carbon hotkey (a dev instance must not
    /// grab system combos while the live app runs) and never posts CGEvents.
    private var isAutomationMode = false
    /// Fixture ids manufactured by the all-history drift flow so the result
    /// receipt can assert both stay invisible.
    private var automationDriftedEventID = ""
    private var automationDoNotIndexEventID = ""
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        isPaused = userDefaults.bool(forKey: "capturePaused")
        settings = settingsStore.load()
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusIcon()
        updateLastNonSelfApp(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        hotKeyManager.onHotKey = { [weak self] id in
            guard id == Self.quickPickerHotKeyID else {
                return
            }
            self?.toggleQuickPicker()
        }
        rebuildMenu()
#if DEBUG
        if runUIAutomationIfRequested() {
            return
        }
#endif
        applyQuickPickerShortcut()
        // Seed the live-event estimate with one startup scan so per-capture
        // retention checks stay in memory afterwards.
        applyRetentionLimitIfNeeded()
        restartTimer()
        if !settings.hasCompletedOnboarding {
            lastStatus = "Choose privacy settings to begin"
            rebuildMenu()
            showOnboarding()
        }
    }

    private func pollPasteboard() {
        if settings.isTemporarilyPaused {
            isPaused = true
            configureStatusIcon()
            return
        } else if isPaused, settings.pauseUntil != nil {
            settings.pauseUntil = nil
            try? settingsStore.save(settings)
            isPaused = false
            configureStatusIcon()
            lastStatus = "Capture resumed"
            rebuildMenu()
        }

        guard !isPaused else {
            return
        }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }
        lastChangeCount = changeCount

        guard let content = pasteboard.string(forType: .string), !content.isEmpty else {
            return
        }

        guard settings.archiveEnabled else {
            lastStatus = "Archive off \(shortDate(Date()))"
            rebuildMenu()
            return
        }

        let contentHash = content.hashValue
        guard contentHash != lastContentHash else {
            return
        }
        lastContentHash = contentHash

        let sourceApp = detectedSourceApp()
        let capture = ClipboardCapture(
            capturedAt: Date(),
            content: content,
            sourceApp: sourceApp,
            pasteboardTypes: pasteboard.types?.map(\.rawValue) ?? []
        )

        do {
            switch try ingestor.ingest(capture) {
            case let .stored(_, indexUpdate):
                capturedCount += 1
                lastStatus = indexUpdate == .failed
                    ? "Captured; index update pending"
                    : "Captured \(shortDate(Date()))"
                liveEventCountEstimate = liveEventCountEstimate.map { $0 + 1 }
                markQuickPickerCacheDirty()
                applyRetentionLimitIfNeeded()
            case .blocked:
                blockedCount += 1
                lastStatus = "Blocked sensitive item \(shortDate(Date()))"
            }
            rebuildMenu()
        } catch {
            lastStatus = "Archive error"
            showError("Archive write failed: \(error)")
        }
    }

    @objc private func togglePause() {
        isPaused.toggle()
        settings.pauseUntil = nil
        try? settingsStore.save(settings)
        userDefaults.set(isPaused, forKey: "capturePaused")
        configureStatusIcon()
        lastStatus = isPaused ? "Paused by user" : "Capture resumed"
        rebuildMenu()
    }

    @objc private func pause15Minutes() {
        pauseFor(minutes: 15)
    }

    @objc private func pauseOneHour() {
        pauseFor(minutes: 60)
    }

    @objc private func pauseUntilTomorrow() {
        let tomorrow = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        settings.pauseUntil = tomorrow
        isPaused = true
        saveSettingsAndRefresh("Paused until tomorrow")
    }

    private func pauseFor(minutes: Int) {
        settings.pauseUntil = Calendar.current.date(byAdding: .minute, value: minutes, to: Date())
        isPaused = true
        saveSettingsAndRefresh("Paused for \(minutes)m")
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        updateLastNonSelfApp(app)
    }

    @objc private func refreshMenu() {
        rebuildMenu()
    }

    @objc private func rebuildIndex() {
        do {
            let count = try ClipboardDerivedIndex(archiveRoot: archiveRoot).rebuild()
            lastStatus = "Indexed \(count) items"
            rebuildMenu()
        } catch {
            showError("Index rebuild failed: \(error)")
        }
    }

    @objc private func openArchiveFolder() {
        NSWorkspace.shared.open(archiveRoot)
    }

    @objc private func openClipboardWindow() {
        showClipboardWindow(focusSearch: false, activate: true)
    }

    @objc private func openClipboardSearch() {
        showClipboardWindow(focusSearch: true, activate: true)
    }

    private func showClipboardWindow(focusSearch: Bool, activate: Bool) {
        if panelController == nil {
            panelController = ClipboardPanelController(
                archiveRoot: archiveRoot,
                recentItemLimit: settings.recentItemLimit,
                historyWindow: settings.historyWindow,
                copyToPasteboard: { [weak self] content in
                    self?.copyToPasteboardWithoutRecapture(content)
                },
                onArchiveMutation: { [weak self] in
                    // History-window deletes must invalidate the picker's
                    // warm cache: a stale in-memory event still carries
                    // contentInline, and copy-back would resurrect content
                    // the user explicitly deleted.
                    self?.markQuickPickerCacheDirty()
                }
            )
        }
        panelController?.show(
            recentItemLimit: settings.recentItemLimit,
            historyWindow: settings.historyWindow,
            focusSearch: focusSearch,
            activate: activate
        )
    }

    @objc private func showPreferences() {
        showSettingsWindow(activate: true)
    }

    // MARK: - Quick picker (expansion contract 8)

    @objc private func openQuickPicker() {
        toggleQuickPicker()
    }

    /// The one entry point for the picker: invoked by the global hotkey, the
    /// menu item, and the DEBUG automation harness.
    private func toggleQuickPicker() {
        if quickPickerController == nil {
            quickPickerController = QuickPickerPanelController(
                dependencies: QuickPickerPanelController.Dependencies(
                    loadEvents: { [weak self] in
                        self?.quickPickerEvents() ?? []
                    },
                    copyToPasteboard: { [weak self] event in
                        // Wraps the ONE shared no-re-capture copy path.
                        guard let self,
                              let content = try? self.reader.content(for: event) else {
                            return nil
                        }
                        self.copyToPasteboardWithoutRecapture(content)
                        return content
                    },
                    directPasteAllowed: { [weak self] in
                        guard let self else {
                            return false
                        }
#if DEBUG
                        if self.isAutomationMode {
                            return false
                        }
#endif
                        return self.settings.quickPickerDirectPasteEnabled && AXIsProcessTrusted()
                    },
                    performDirectPaste: { [weak self] in
                        self?.performDirectPaste()
                    }
                )
            )
        }
        quickPickerController?.toggle()
    }

    /// Picker event loader: warm cache when clean, one bounded
    /// `recentItems` scan when dirty.
    private func quickPickerEvents() -> [StoredClipboardEvent] {
        if !quickPickerCacheDirty {
            return quickPickerCache
        }
        let since = Calendar.current.date(
            byAdding: .day,
            value: -settings.historyWindow.dayCount,
            to: Date()
        ) ?? Date()
        quickPickerCache = (try? reader.recentItems(
            since: since,
            limit: settings.recentItemLimit
        )) ?? []
        quickPickerCacheDirty = false
        return quickPickerCache
    }

    private func markQuickPickerCacheDirty() {
        quickPickerCacheDirty = true
    }

    /// Registers (or clears) the quick picker hotkey from settings. Called
    /// on launch, after every settings save, and when shortcut recording
    /// ends. Registration failures surface in Settings and the menu — the
    /// shortcut stays saved but is reported as not active.
    private func applyQuickPickerShortcut() {
#if DEBUG
        guard !isAutomationMode else {
            return
        }
#endif
        hotKeyManager.unregister(id: Self.quickPickerHotKeyID)
        shortcutFailureMessage = nil
        settingsWindowController?.showShortcutRegistrationFailure(nil)
        let shortcut = settings.quickPickerShortcut
        guard shortcut.enabled, shortcut.isValid else {
            return
        }
        switch hotKeyManager.register(
            id: Self.quickPickerHotKeyID,
            keyCode: UInt32(shortcut.keyCode),
            carbonModifiers: shortcut.carbonModifierFlags
        ) {
        case .registered:
            break
        case let .conflict(status):
            surfaceShortcutFailure(
                "\(shortcut.displayString) is already in use by another app (error \(status)). The shortcut is saved but not active."
            )
        case let .failed(status):
            surfaceShortcutFailure(
                "Could not register \(shortcut.displayString) (error \(status)). The shortcut is saved but not active."
            )
        }
    }

    private func surfaceShortcutFailure(_ message: String) {
        // Durable surfaces (contract 8: never silent): a persistent menu
        // warning item survives status-line churn, and the message is pushed
        // into the Settings window whenever it exists or is later created.
        shortcutFailureMessage = message
        lastStatus = "Quick picker shortcut not active"
        settingsWindowController?.showShortcutRegistrationFailure(message)
        rebuildMenu()
    }

    /// Direct paste: opt-in, re-checks the setting AND Accessibility trust
    /// on every call, and degrades to plain copy-back silently (never a
    /// dialog). Posts ⌘V (virtual key 9) to the HID event tap.
    private func performDirectPaste() {
#if DEBUG
        guard !isAutomationMode else {
            return
        }
#endif
        guard settings.quickPickerDirectPasteEnabled, AXIsProcessTrusted() else {
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func showSettingsWindow(activate: Bool) {
        if settingsWindowController == nil {
            let controller = ClipboardSettingsWindowController(
                settings: settings,
                settingsStore: settingsStore,
                archiveRoot: archiveRoot
            )
            controller.delegate = self
            settingsWindowController = controller
        }
        settingsWindowController?.show(settings: settings, activate: activate)
        if let shortcutFailureMessage {
            settingsWindowController?.showShortcutRegistrationFailure(shortcutFailureMessage)
        }
    }

    func clipboardSettingsWindow(_ controller: ClipboardSettingsWindowController, didSave settings: ClipboardSettings) {
        let previousInterval = self.settings.pollIntervalSeconds
        if self.settings.retentionMode != settings.retentionMode {
            liveEventCountEstimate = nil
        }
        self.settings = settings
        ingestor = ClipboardIngestor(
            filter: ClipboardPrivacyFilter(settings: settings),
            archiveWriter: archiveWriter,
            derivedIndex: derivedIndex
        )
        if previousInterval != settings.pollIntervalSeconds {
            restartTimer()
        }
        markQuickPickerCacheDirty()
        applyQuickPickerShortcut()
        lastStatus = settings.archiveEnabled ? "Settings saved" : "Archive tracking off"
        rebuildMenu()
        // The settings window hides itself right after save, so a
        // registration failure discovered here needs its own visible
        // surface, not just the (now hidden) conflict label.
        if let shortcutFailureMessage {
            let alert = NSAlert()
            alert.messageText = "Quick Picker Shortcut Not Active"
            alert.informativeText = shortcutFailureMessage
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func clipboardSettingsWindowWillBeginShortcutRecording(_ controller: ClipboardSettingsWindowController) {
        // Suspend the live registration so pressing the current combo
        // records it instead of opening the picker.
        hotKeyManager.unregister(id: Self.quickPickerHotKeyID)
    }

    func clipboardSettingsWindowDidEndShortcutRecording(_ controller: ClipboardSettingsWindowController) {
        applyQuickPickerShortcut()
    }

    private func showOnboarding(activate: Bool = true) {
        if onboardingWindowController == nil {
            let controller = ClipboardOnboardingWindowController(archiveRoot: archiveRoot)
            controller.delegate = self
            onboardingWindowController = controller
        }
        onboardingWindowController?.show(activate: activate)
#if DEBUG
        if let choice = ProcessInfo.processInfo.environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_CHOICE"],
           !choice.isEmpty {
            let controller = onboardingWindowController
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller?.performAutomationChoice(choice)
            }
        }
#endif
    }

#if DEBUG
    private func runUIAutomationIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let screen = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN"],
              !screen.isEmpty,
              let snapshotPath = environment["CLIPBOARD_ARCHIVE_UI_SNAPSHOT_PATH"],
              !snapshotPath.isEmpty else {
            return false
        }

        let supportRoot = ClipboardDefaults.applicationSupportRoot()
        guard archiveRoot.standardizedFileURL.path.hasPrefix("/tmp/"),
              supportRoot.standardizedFileURL.path.hasPrefix("/tmp/") else {
            FileHandle.standardError.write(
                Data("UI automation requires isolated /tmp archive and support roots.\n".utf8)
            )
            NSApp.terminate(nil)
            return true
        }

        isAutomationMode = true
        // Pasteboard isolation: automation commits copy to a private named
        // pasteboard so gestures never clobber the real clipboard. The
        // capture-poll dedup state is reseeded against the same pasteboard
        // so the no-re-capture receipt exercises the production path.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("app.clipboardarchive.ui-automation"))
        lastChangeCount = pasteboard.changeCount

        settings = ClipboardSettings(
            excludedBundleIdentifiers: ["com.example.passwords"],
            pollIntervalSeconds: 0.2,
            archiveEnabled: environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED"] == "1",
            recentItemLimit: 50,
            historyWindow: .fourteenDays,
            retentionMode: .recent50,
            hasCompletedOnboarding: true
        )

        do {
            try settingsStore.save(settings)
            if screen == "history" {
                try seedSyntheticUIFixtures()
                let scopeRequest = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCOPE"] ?? "working"
                if scopeRequest == "all-history" {
                    try seedAllHistoryDriftFixtures()
                }
                showClipboardWindow(focusSearch: false, activate: false)
                if scopeRequest == "all-history" {
                    panelController?.performAutomationScope("all-history")
                }
                panelController?.performAutomationSearch(
                    environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_QUERY"] ?? ""
                )
                panelController?.performAutomationTypeFilter(
                    environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_TYPE_FILTER"] ?? "all"
                )
                if let dateFilter = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_DATE_FILTER"],
                   !dateFilter.isEmpty {
                    panelController?.performAutomationDateFilter(dateFilter)
                }
                if let appFilter = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_APP_FILTER"],
                   !appFilter.isEmpty {
                    panelController?.performAutomationAppFilter(appFilter)
                }
            } else if screen == "settings" {
                showSettingsWindow(activate: false)
            } else if screen == "onboarding" {
                showOnboarding(activate: false)
            } else if screen == "quickpicker" {
                try seedSyntheticUIFixtures()
                // Same entry point the global hotkey invokes; automation
                // mode never registers the Carbon hotkey itself.
                toggleQuickPicker()
                if let query = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_QUERY"],
                   !query.isEmpty {
                    quickPickerController?.performAutomationQuery(query)
                }
            } else {
                throw NSError(
                    domain: "ClipboardArchiveUIAutomation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown UI automation screen."]
                )
            }
        } catch {
            FileHandle.standardError.write(Data("UI automation setup failed: \(error)\n".utf8))
            NSApp.terminate(nil)
            return true
        }

        if screen == "history" {
            // History (both scopes) settles by polling instead of a fixed
            // sleep: 0.1 s steps with a 5 s cap. On timeout the snapshot is
            // still written — the receipt records the unsettled state.
            let deadline = Date().addingTimeInterval(5.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.pollHistoryAutomationSettled(deadline: deadline) { [weak self] in
                    let url = URL(fileURLWithPath: snapshotPath)
                    do {
                        try self?.panelController?.writeSnapshot(to: url)
                    } catch {
                        FileHandle.standardError.write(Data("UI snapshot failed: \(error)\n".utf8))
                    }
                    self?.writeHistoryAutomationResult()
                    NSApp.terminate(nil)
                }
            }
            return true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            let url = URL(fileURLWithPath: snapshotPath)
            do {
                switch screen {
                case "settings":
                    try self?.settingsWindowController?.writeSnapshot(to: url)
                case "onboarding":
                    try self?.onboardingWindowController?.writeSnapshot(to: url)
                case "quickpicker":
                    self?.runQuickPickerAutomation(snapshotURL: url)
                default:
                    break
                }
            } catch {
                FileHandle.standardError.write(Data("UI snapshot failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private func pollHistoryAutomationSettled(
        deadline: Date,
        completion: @escaping () -> Void
    ) {
        if panelController?.automationIsSettled ?? true || Date() >= deadline {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollHistoryAutomationSettled(deadline: deadline, completion: completion)
        }
    }

    /// Manufactures the stale-index + ledger-drift condition the design
    /// demands the snapshot prove (read-time suppression, not rebuild-time
    /// luck):
    /// 1. append one hand-built doNotIndex event line (must never appear in
    ///    the index or any result),
    /// 2. rebuild the index so every live seeded event is indexed,
    /// 3. THEN record a deletion for one seeded event WITHOUT the matching
    ///    index delete — the index still holds the row; only read-time
    ///    suppression can keep it out of results.
    private func seedAllHistoryDriftFixtures() throws {
        let capturedAt = Date().addingTimeInterval(-30 * 60)
        let body = "synthetic doNotIndex fixture launch checklist secret-shaped note"
        let compactFormatter = DateFormatter()
        compactFormatter.calendar = Calendar(identifier: .gregorian)
        compactFormatter.locale = Locale(identifier: "en_US_POSIX")
        compactFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        compactFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let doNotIndexEvent = StoredClipboardEvent(
            id: "clip_\(compactFormatter.string(from: capturedAt))_donotindexff_aa11bb22",
            capturedAt: capturedAt,
            contentType: .text,
            contentHash: "sha256:synthetic-donotindex",
            contentPreview: body,
            contentInline: body,
            rawContentPath: nil,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: body.utf8.count,
            characterCount: body.count,
            lineCount: 1,
            privacyLabel: .doNotIndex,
            allowedUse: [.doNotIndex],
            sensitivityFlags: [],
            uiVisibleUntil: capturedAt.addingTimeInterval(7 * 86_400)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(doNotIndexEvent)
        line.append(0x0A)
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy/MM/yyyy-MM-dd"
        let dayFile = archiveRoot.appendingPathComponent(
            "raw/\(dayFormatter.string(from: capturedAt))_clipboard-events.ndjson"
        )
        if FileManager.default.fileExists(atPath: dayFile.path) {
            let handle = try FileHandle(forWritingTo: dayFile)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try FileManager.default.createDirectory(
                at: dayFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try line.write(to: dayFile, options: [.atomic])
        }
        automationDoNotIndexEventID = doNotIndexEvent.id

        // Index every currently-live event, THEN manufacture ledger drift.
        _ = try derivedIndex.rebuild()
        let seeded = try reader.recentItems(since: Date(timeIntervalSince1970: 0), limit: 100)
        guard let driftTarget = seeded.first(where: { $0.sourceApp.name == "Xcode" })
            ?? seeded.first else {
            return
        }
        try ClipboardDeletionLedger(archiveRoot: archiveRoot).recordDeletion(
            eventID: driftTarget.id,
            reason: "ui-automation-drift"
        )
        automationDriftedEventID = driftTarget.id
    }

    /// Machine-readable receipt for the history automation run: counts,
    /// state, and proof that the drifted and doNotIndex fixtures stayed
    /// invisible.
    private func writeHistoryAutomationResult() {
        let environment = ProcessInfo.processInfo.environment
        guard let resultPath = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH"],
              !resultPath.isEmpty else {
            return
        }
        let visibleIDs = panelController?.automationVisibleResultIDs ?? []
        let result: [String: Any] = [
            "scope": environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCOPE"] ?? "working",
            "state": panelController?.automationStateName ?? "unknown",
            "settled": panelController?.automationIsSettled ?? false,
            "resultCount": panelController?.automationRowCount ?? -1,
            "visibleIDs": visibleIDs,
            "driftedEventID": automationDriftedEventID,
            "doNotIndexEventID": automationDoNotIndexEventID,
            "driftedEventVisible": !automationDriftedEventID.isEmpty
                && visibleIDs.contains(automationDriftedEventID),
            "doNotIndexEventVisible": !automationDoNotIndexEventID.isEmpty
                && visibleIDs.contains(automationDoNotIndexEventID)
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: resultPath), options: [.atomic])
        }
    }

    /// Applies the requested gesture list through the picker's production
    /// key handlers, runs one capture-poll tick (the no-re-capture receipt),
    /// then writes the snapshot PNG and the machine-readable result JSON.
    private func runQuickPickerAutomation(snapshotURL: URL) {
        let environment = ProcessInfo.processInfo.environment
        let eventCountBefore = archiveEventCount()

        if let gestures = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_GESTURES"],
           !gestures.isEmpty {
            for gesture in gestures.split(separator: ",") {
                quickPickerController?.performAutomationGesture(String(gesture))
            }
        }

        // One poll tick: with archiveEnabled=true this asserts that a picker
        // commit is NOT re-captured as a new archive event (the shared copy
        // helper already synced the dedup state).
        pollPasteboard()
        let eventCountAfter = archiveEventCount()

        try? quickPickerController?.writeSnapshot(to: snapshotURL)

        if let resultPath = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH"],
           !resultPath.isEmpty {
            let committed = quickPickerController?.automationLastCommittedContent
            let pasteboardString = pasteboard.string(forType: .string)
            let result: [String: Any] = [
                "filteredCount": quickPickerController?.automationFilteredCount ?? -1,
                "selectedPreviewPrefix": String(
                    (quickPickerController?.automationLastSelectedPreview ?? "").prefix(24)
                ),
                "pasteboardMatchesSelection": committed != nil && pasteboardString == committed,
                "pickerVisibleAfterGestures": quickPickerController?.isVisible ?? false,
                "openElapsedMilliseconds":
                    quickPickerController?.automationLastOpenElapsedMilliseconds ?? -1,
                "eventCountBefore": eventCountBefore,
                "eventCountAfter": eventCountAfter
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: URL(fileURLWithPath: resultPath), options: [.atomic])
            }
        }
    }

    private func archiveEventCount() -> Int {
        let epoch = Date(timeIntervalSince1970: 0)
        return (try? reader.recentItems(since: epoch, limit: Int.max))?.count ?? -1
    }

    private func seedSyntheticUIFixtures() throws {
        let fixtures: [(minutesAgo: TimeInterval, content: String, app: ClipboardSourceApp)] = [
            (
                3,
                "Review the launch checklist before Friday, then send the final notes to the team.",
                ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
            ),
            (
                18,
                "https:" + "//example.com/design/clipboard-history",
                ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari")
            ),
            (
                47,
                "struct ClipRow {\n    let title: String\n    let copiedAt: Date\n}",
                ClipboardSourceApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")
            ),
            (
                95,
                "Synthetic fixture: customer interview notes belong here, never real customer data.",
                ClipboardSourceApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
            ),
            (
                180,
                "A local clipboard should feel quiet, trustworthy, and instantly searchable.",
                ClipboardSourceApp(name: "Messages", bundleIdentifier: "com.apple.MobileSMS")
            )
        ]
        for fixture in fixtures {
            try archiveWriter.archiveAllowedCapture(
                ClipboardCapture(
                    capturedAt: Date().addingTimeInterval(-fixture.minutesAgo * 60),
                    content: fixture.content,
                    sourceApp: fixture.app,
                    pasteboardTypes: ["public.utf8-plain-text"]
                )
            )
        }
    }
#endif

    func clipboardOnboardingWindow(
        _ controller: ClipboardOnboardingWindowController,
        didChooseArchiveEnabled archiveEnabled: Bool,
        retentionMode: ClipboardRetentionMode
    ) {
        settings.archiveEnabled = archiveEnabled
        settings.retentionMode = retentionMode
        settings.recentItemLimit = retentionMode.retainedItemLimit ?? settings.recentItemLimit
        settings.hasCompletedOnboarding = true
        liveEventCountEstimate = nil
        isPaused = false
        saveSettingsAndRefresh(
            archiveEnabled
                ? "\(retentionMode.displayName) capture enabled"
                : "Capture remains off"
        )
    }

    private func applyRetentionLimitIfNeeded() {
        guard let limit = settings.retentionMode.retainedItemLimit else {
            liveEventCountEstimate = nil
            return
        }
        // Common case: the in-memory estimate proves we are at or under the
        // limit, so no archive scanning happens at all. The estimate only
        // overshoots (deletes are not subtracted), which is safe: an
        // overshoot merely triggers one enforcement scan that refreshes it.
        // Exception: another process (e.g. the CLI monitor pointed at the
        // same archive root) can append events this counter never sees, so
        // the estimate could undercount and silently stop enforcing the
        // user's retention choice. A periodic forced reseed bounds that
        // window to a handful of captures.
        capturesSinceRetentionScan += 1
        if capturesSinceRetentionScan < Self.retentionRescanInterval,
           let estimate = liveEventCountEstimate, estimate <= limit {
            return
        }
        capturesSinceRetentionScan = 0
        do {
            let result = try ClipboardArchivePruner(archiveRoot: archiveRoot)
                .enforceRetentionLimit(
                    keepingMostRecent: limit,
                    reason: "retention-\(settings.retentionMode.rawValue)"
                )
            liveEventCountEstimate = result.keptEvents
            if result.prunedEvents > 0 {
                lastStatus = "Kept latest \(limit), pruned \(result.prunedEvents)"
                markQuickPickerCacheDirty()
            }
        } catch {
            lastStatus = "Retention prune failed"
        }
    }

    @objc private func showArchiveHealth() {
        do {
            let health = try ClipboardArchiveHealthReporter(archiveRoot: archiveRoot).health()
            let alert = NSAlert()
            alert.messageText = "Clipboard Archive Health"
            alert.informativeText = """
            Stored: \(health.storedEvents)
            Blocked: \(health.blockedEvents)
            Deleted: \(health.deletedEvents)
            Today: \(health.todayStoredEvents)
            Last 7 days: \(health.lastSevenDaysStoredEvents)
            Large bodies: \(health.largeBodyFiles)
            Missing bodies: \(health.missingBodyFiles)
            Unsafe body paths: \(health.unsafeBodyPaths)
            Files with broad permissions: \(health.insecureFiles)
            Invalid JSON: \(health.invalidJSONLines)
            Archive size: \(formatBytes(health.archiveBytes))
            Index size: \(formatBytes(health.indexBytes))
            Index stale: \(health.indexIsStale ? "yes" : "no")
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            showError("Health check failed: \(error)")
        }
    }

    @objc private func excludeCurrentApp() {
        let source = detectedSourceApp()
        guard let bundle = source.bundleIdentifier, !bundle.isEmpty else {
            showError("No bundle identifier found for current app.")
            return
        }
        if !settings.excludedBundleIdentifiers.contains(bundle) {
            settings.excludedBundleIdentifiers.append(bundle)
            settings.excludedBundleIdentifiers.sort()
        }
        saveSettingsAndRefresh("Excluded \(source.name)")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let pauseLine = settings.pauseUntil.map { " until \(shortDate($0))" } ?? ""
        let statusTitle: String
        if isPaused {
            statusTitle = "Capture Paused\(pauseLine)"
        } else if settings.archiveEnabled {
            statusTitle = settings.retentionMode.storesLongTermHistory ? "Full Archive Active" : "\(settings.retentionMode.displayName) Active"
        } else {
            statusTitle = "Archive Tracking Off"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let last = NSMenuItem(title: lastStatus, action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)
        let counters = NSMenuItem(title: "\(capturedCount) captured, \(blockedCount) blocked this run", action: nil, keyEquivalent: "")
        counters.isEnabled = false
        menu.addItem(counters)
        if shortcutFailureMessage != nil {
            let warning = NSMenuItem(
                title: "⚠ Quick Picker Shortcut Not Active…",
                action: #selector(showPreferences),
                keyEquivalent: ""
            )
            warning.target = self
            warning.toolTip = shortcutFailureMessage
            menu.addItem(warning)
        }
        menu.addItem(NSMenuItem.separator())

        let recent = (try? reader.recentItems(since: sevenDaysAgo(), limit: 60)) ?? []
        let quickTitle = NSMenuItem(title: "Recent Clips", action: nil, keyEquivalent: "")
        quickTitle.isEnabled = false
        menu.addItem(quickTitle)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No captured text yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for event in recent.prefix(5) {
                menu.addItem(quickCopyMenuItem(for: event))
            }
        }
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quick Picker", action: #selector(openQuickPicker), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Clipboard History…", action: #selector(openClipboardWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Search History…", action: #selector(openClipboardSearch), keyEquivalent: "f"))
        menu.addItem(NSMenuItem(title: isPaused ? "Resume Capture" : "Pause Capture", action: #selector(togglePause), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())

        let recentMenu = NSMenuItem(title: "More Recent Items", action: nil, keyEquivalent: "")
        let recentSubmenu = NSMenu()
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No captured text yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentSubmenu.addItem(empty)
        } else {
            for event in recent.dropFirst(5) {
                recentSubmenu.addItem(menuItem(for: event))
            }
            if recent.count <= 5 {
                let empty = NSMenuItem(title: "No additional items", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                recentSubmenu.addItem(empty)
            }
        }
        recentMenu.submenu = recentSubmenu
        menu.addItem(recentMenu)

        let maintenance = NSMenuItem(title: "Maintenance", action: nil, keyEquivalent: "")
        let maintenanceSubmenu = NSMenu()
        maintenanceSubmenu.addItem(NSMenuItem(title: "Archive Health", action: #selector(showArchiveHealth), keyEquivalent: "h"))
        maintenanceSubmenu.addItem(NSMenuItem(title: "Rebuild Search Index", action: #selector(rebuildIndex), keyEquivalent: ""))
        maintenanceSubmenu.addItem(NSMenuItem(title: "Delete Latest Item...", action: #selector(deleteLatestItem), keyEquivalent: "d"))
        maintenanceSubmenu.addItem(NSMenuItem(title: "Exclude Current App", action: #selector(excludeCurrentApp), keyEquivalent: ""))
        let fullArchive = NSMenuItem(
            title: "Keep Full Archive",
            action: #selector(toggleFullArchive),
            keyEquivalent: ""
        )
        fullArchive.state = settings.retentionMode.storesLongTermHistory ? .on : .off
        maintenanceSubmenu.addItem(fullArchive)
        maintenanceSubmenu.addItem(NSMenuItem.separator())
        let pauseMenu = NSMenuItem(title: "Pause For", action: nil, keyEquivalent: "")
        let pauseSubmenu = NSMenu()
        pauseSubmenu.addItem(NSMenuItem(title: "15 Minutes", action: #selector(pause15Minutes), keyEquivalent: ""))
        pauseSubmenu.addItem(NSMenuItem(title: "1 Hour", action: #selector(pauseOneHour), keyEquivalent: ""))
        pauseSubmenu.addItem(NSMenuItem(title: "Until Tomorrow", action: #selector(pauseUntilTomorrow), keyEquivalent: ""))
        pauseMenu.submenu = pauseSubmenu
        maintenanceSubmenu.addItem(pauseMenu)
        maintenanceSubmenu.addItem(NSMenuItem(title: "Refresh Menu", action: #selector(refreshMenu), keyEquivalent: "r"))
        maintenanceSubmenu.addItem(NSMenuItem(title: "Open Archive Folder", action: #selector(openArchiveFolder), keyEquivalent: ""))
        maintenance.submenu = maintenanceSubmenu
        menu.addItem(maintenance)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleFullArchive() {
        if settings.retentionMode.storesLongTermHistory {
            settings.retentionMode = .recent50
            settings.recentItemLimit = 50
            lastStatus = "Full archive off, keeping 50"
            liveEventCountEstimate = nil
            applyRetentionLimitIfNeeded()
        } else {
            settings.retentionMode = .unlimited
            lastStatus = "Full archive on"
        }
        settings.archiveEnabled = true
        settings.hasCompletedOnboarding = true
        try? settingsStore.save(settings)
        markQuickPickerCacheDirty()
        rebuildMenu()
    }

    private func quickCopyMenuItem(for event: StoredClipboardEvent) -> NSMenuItem {
        let item = NSMenuItem(
            title: "\(shortDate(event.capturedAt))  \(trimmedPreview(event.contentPreview))",
            action: #selector(copyEvent(_:)),
            keyEquivalent: ""
        )
        item.representedObject = event.id
        return item
    }

    private func menuItem(for event: StoredClipboardEvent) -> NSMenuItem {
        let item = NSMenuItem(title: "\(shortDate(event.capturedAt))  \(trimmedPreview(event.contentPreview))", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let copy = NSMenuItem(title: "Copy", action: #selector(copyEvent(_:)), keyEquivalent: "")
        copy.representedObject = event.id
        submenu.addItem(copy)

        let delete = NSMenuItem(title: "Delete Content From Archive", action: #selector(deleteEvent(_:)), keyEquivalent: "")
        delete.representedObject = event.id
        submenu.addItem(delete)

        let info = NSMenuItem(title: "\(event.byteCount)b from \(event.sourceApp.name)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        submenu.addItem(info)

        item.submenu = submenu
        return item
    }

    @objc private func copyEvent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let event = try? reader.recentItems(since: sevenDaysAgo(), limit: 200).first(where: { $0.id == id }),
              let content = try? reader.content(for: event) else {
            return
        }

        copyToPasteboardWithoutRecapture(content)
    }

    /// The ONE copy-back path (expansion contract 2): sets the pasteboard
    /// AND updates the capture dedup state (`lastChangeCount` and
    /// `lastContentHash`) so copying an archived clip back out is never
    /// re-captured as a new duplicate event. Every copy-back surface — the
    /// menu quick-copy above, the History window (wired via the panel's
    /// `copyToPasteboard` closure), and the future quick picker — MUST route
    /// through this method instead of touching the pasteboard directly.
    private func copyToPasteboardWithoutRecapture(_ content: String) {
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        lastContentHash = content.hashValue
        lastChangeCount = pasteboard.changeCount
    }

    @objc private func deleteEvent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        guard confirmDelete() else {
            return
        }
        do {
            try redactor.redact(eventID: id)
            lastStatus = "Deleted item \(shortDate(Date()))"
            markQuickPickerCacheDirty()
            rebuildMenu()
        } catch {
            showError("Delete failed: \(error)")
        }
    }

    @objc private func deleteLatestItem() {
        guard let event = try? reader.recentItems(since: sevenDaysAgo(), limit: 1).first else {
            showError("No recent item to delete.")
            return
        }
        guard confirmDelete() else {
            return
        }
        do {
            try redactor.redact(eventID: event.id)
            lastStatus = "Deleted latest item \(shortDate(Date()))"
            markQuickPickerCacheDirty()
            rebuildMenu()
        } catch {
            showError("Delete failed: \(error)")
        }
    }

    private func sevenDaysAgo() -> Date {
        Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Clipboard Archive"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func confirmDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete Clipboard Content?"
        alert.informativeText = "This redacts inline archive content, removes large body files, and hides the item from recent/search. Timeline metadata remains."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func trimmedPreview(_ preview: String) -> String {
        if preview.count <= 72 {
            return preview
        }
        return String(preview.prefix(69)) + "..."
    }

    private func detectedSourceApp() -> ClipboardSourceApp {
        let app = NSWorkspace.shared.frontmostApplication
        if let app, app.bundleIdentifier != "app.clipboardarchive" {
            let source = ClipboardSourceApp(
                name: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier
            )
            lastNonSelfApp = source
            return source
        }
        return lastNonSelfApp
    }

    private func updateLastNonSelfApp(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != "app.clipboardarchive" else {
            return
        }
        lastNonSelfApp = ClipboardSourceApp(
            name: app.localizedName ?? "Unknown",
            bundleIdentifier: app.bundleIdentifier
        )
    }

    private func saveSettingsAndRefresh(_ status: String) {
        do {
            try settingsStore.save(settings)
            ingestor = ClipboardIngestor(
                filter: ClipboardPrivacyFilter(settings: settings),
                archiveWriter: archiveWriter,
                derivedIndex: derivedIndex
            )
            userDefaults.set(isPaused, forKey: "capturePaused")
            markQuickPickerCacheDirty()
            applyQuickPickerShortcut()
            lastStatus = status
            restartTimer()
            configureStatusIcon()
            rebuildMenu()
        } catch {
            showError("Could not save settings: \(error)")
        }
    }

    private func configureStatusIcon() {
        let symbolName = isPaused || !settings.archiveEnabled ? "pause.circle" : "doc.on.clipboard"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipboard Archive") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = isPaused ? "Archive Paused" : "Archive"
        }
        if isPaused {
            statusItem.button?.toolTip = "Clipboard Archive: paused"
        } else if settings.archiveEnabled {
            statusItem.button?.toolTip = "Clipboard Archive: capturing"
        } else {
            statusItem.button?.toolTip = "Clipboard Archive: archive tracking off"
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

let instanceLock = AppInstanceLock()
guard instanceLock.acquire() else {
    exit(0)
}

let app = NSApplication.shared
let delegate = ClipboardMenuBarApp()
app.delegate = delegate
app.run()
