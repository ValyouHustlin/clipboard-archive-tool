import ClipboardArchiveCore
import AppKit
import Foundation

private let archiveRoot = ClipboardDefaults.archiveRoot()

@MainActor
final class ClipboardMenuBarApp: NSObject, NSApplicationDelegate, ClipboardSettingsWindowControllerDelegate {
    private let userDefaults = UserDefaults.standard
    private let settingsStore = ClipboardSettingsStore()
    private var settings = ClipboardSettings()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var isPaused = false
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastContentHash: Int?
    private let pasteboard = NSPasteboard.general
    private let archiveWriter = ClipboardArchiveWriter(archiveRoot: archiveRoot)
    private lazy var ingestor = ClipboardIngestor(
        filter: ClipboardPrivacyFilter(settings: settings),
        archiveWriter: archiveWriter
    )
    private let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
    private let redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
    private var capturedCount = 0
    private var blockedCount = 0
    private var lastStatus = "Ready"
    private var lastNonSelfApp = ClipboardSourceApp(name: "Unknown", bundleIdentifier: nil)
    private var panelController: ClipboardPanelController?
    private var settingsWindowController: ClipboardSettingsWindowController?

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
        rebuildMenu()
        restartTimer()
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
            case .stored:
                capturedCount += 1
                lastStatus = "Captured \(shortDate(Date()))"
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
        if panelController == nil {
            panelController = ClipboardPanelController(
                archiveRoot: archiveRoot,
                pasteboard: pasteboard,
                recentItemLimit: settings.recentItemLimit
            )
        }
        panelController?.show(recentItemLimit: settings.recentItemLimit)
    }

    @objc private func searchRecent() {
        let alert = NSAlert()
        alert.messageText = "Search Clipboard Archive"
        alert.informativeText = "Searches local archive content. Results exclude deleted items."
        alert.addButton(withTitle: "Search")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "Search text, URLs, or code"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let query = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return
        }

        do {
            let results = try ClipboardArchiveSearcher(archiveRoot: archiveRoot)
                .search(ClipboardSearchOptions(query: query, since: sevenDaysAgo(), limit: 10))
            showSearchResults(query: query, results: results)
        } catch {
            showError("Search failed: \(error)")
        }
    }

    @objc private func showPreferences() {
        if settingsWindowController == nil {
            let controller = ClipboardSettingsWindowController(
                settings: settings,
                settingsStore: settingsStore,
                archiveRoot: archiveRoot
            )
            controller.delegate = self
            settingsWindowController = controller
        }
        settingsWindowController?.show(settings: settings)
    }

    func clipboardSettingsWindow(_ controller: ClipboardSettingsWindowController, didSave settings: ClipboardSettings) {
        let previousInterval = self.settings.pollIntervalSeconds
        self.settings = settings
        ingestor = ClipboardIngestor(
            filter: ClipboardPrivacyFilter(settings: settings),
            archiveWriter: archiveWriter
        )
        if previousInterval != settings.pollIntervalSeconds {
            restartTimer()
        }
        lastStatus = settings.archiveEnabled ? "Settings saved" : "Archive tracking off"
        rebuildMenu()
    }

    private func applyRetentionLimitIfNeeded() {
        guard let limit = settings.retentionMode.retainedItemLimit else {
            return
        }
        do {
            let result = try ClipboardArchivePruner(archiveRoot: archiveRoot)
                .pruneContent(keepingMostRecent: limit, reason: "retention-\(settings.retentionMode.rawValue)")
            if result.prunedEvents > 0 {
                lastStatus = "Kept latest \(limit), pruned \(result.prunedEvents)"
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

    private func showSearchResults(query: String, results: [ClipboardSearchResult]) {
        let alert = NSAlert()
        alert.messageText = "Search Results"
        if results.isEmpty {
            alert.informativeText = "No matches for \"\(query)\" in the visible 7-day window."
        } else {
            alert.informativeText = results.enumerated().map { index, result in
                "\(index + 1). \(shortDate(result.event.capturedAt)) - \(result.event.sourceApp.name)\n\(result.snippet)"
            }.joined(separator: "\n\n")
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        menu.addItem(NSMenuItem.separator())

        let recent = (try? reader.recentItems(since: sevenDaysAgo(), limit: 60)) ?? []
        let quickTitle = NSMenuItem(title: "Last 10 Copied", action: nil, keyEquivalent: "")
        quickTitle.isEnabled = false
        menu.addItem(quickTitle)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No captured text yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for event in recent.prefix(10) {
                menu.addItem(quickCopyMenuItem(for: event))
            }
        }
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Open Clipboard Window", action: #selector(openClipboardWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Search Last 7 Days...", action: #selector(searchRecent), keyEquivalent: "f"))
        menu.addItem(NSMenuItem(title: isPaused ? "Resume Capture" : "Pause Capture", action: #selector(togglePause), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: settings.retentionMode.storesLongTermHistory ? "Turn Off Full Archive" : "Turn On Full Archive", action: #selector(toggleFullArchive), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())

        let recentMenu = NSMenuItem(title: "More Recent Items", action: nil, keyEquivalent: "")
        let recentSubmenu = NSMenu()
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No captured text yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentSubmenu.addItem(empty)
        } else {
            for event in recent.dropFirst(10) {
                recentSubmenu.addItem(menuItem(for: event))
            }
            if recent.count <= 10 {
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
            applyRetentionLimitIfNeeded()
        } else {
            settings.retentionMode = .unlimited
            lastStatus = "Full archive on"
        }
        settings.archiveEnabled = true
        try? settingsStore.save(settings)
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
                archiveWriter: archiveWriter
            )
            userDefaults.set(isPaused, forKey: "capturePaused")
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
