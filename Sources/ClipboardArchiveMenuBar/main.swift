import ClipboardArchiveCore
import AppKit
import ApplicationServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        derivedIndex: derivedIndex,
        richImageMaxBytes: settings.richImageMaxBytes
    )
    private let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
    private let redactor = ClipboardArchiveRedactor(archiveRoot: archiveRoot)
    private let annotationsStore = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
    private let occurrenceResolver = ClipboardOccurrenceResolver(archiveRoot: archiveRoot)
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
    private var dashboardWindowController: ClipboardDashboardWindowController?
    /// True when the previous poll was gated (private mode or pause) — the
    /// capture gate turns the first ungated poll into a resync-only pass so
    /// nothing copied during the gap is retro-captured (Slice 5 fix).
    private var captureGateWasActive = false
    /// The most recent blocked-event reason this run (menu status line,
    /// shown only when `showBlockedEventStatus` is on).
    private var lastBlockedReason: String?
    /// 30-minute expiry enforcement timer (never the capture poll).
    private var expiryTimer: Timer?
    private static let quickPickerHotKeyID: UInt32 = 1
    private let hotKeyManager = GlobalHotKeyManager()
    private var quickPickerController: QuickPickerPanelController?
    /// Warm event list for the quick picker. Invalidated (dirty flag) at
    /// every archive mutation — store, delete, prune, settings save — so
    /// repeat opens are O(1) and a cold open does one `recentItems` scan.
    private var quickPickerCache: [StoredClipboardEvent] = []
    private var quickPickerCacheDirty = true
    /// Warm snippet list for the picker's top section. Invalidated together
    /// with the picker cache (every archive or annotations mutation).
    private var snippetCache: [QuickPickerPanelController.SnippetItem] = []
    private var snippetCacheDirty = true
#if DEBUG
    /// True when the DEBUG UI automation harness drives this instance.
    /// Automation NEVER registers the Carbon hotkey (a dev instance must not
    /// grab system combos while the live app runs) and never posts CGEvents.
    private var isAutomationMode = false
    /// Fixture ids manufactured by the all-history drift flow so the result
    /// receipt can assert both stay invisible.
    private var automationDriftedEventID = ""
    private var automationDoNotIndexEventID = ""
    /// Receipt facts from the pin→prune→survives retention flow.
    private var automationRetentionReceipt: [String: Any] = [:]
    /// Exact bytes of the future-version annotations fixture at seed time,
    /// so the result can prove the file stayed byte-identical.
    private var automationAnnotationsBytesBefore: Data?
    /// Expiry-sweep receipt captured when the harness requests a sweep.
    private var automationSweepReceipt: [String: Any] = [:]
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
        // Expiry enforcement points (Slice 5): launch, a 30-minute timer,
        // and lazy checks when read surfaces open — never the capture poll.
        sweepExpiredIfDue()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sweepExpiredIfDue()
            }
        }
        restartTimer()
        if !settings.hasCompletedOnboarding {
            lastStatus = "Choose privacy settings to begin"
            rebuildMenu()
            showOnboarding()
        }
    }

    private func pollPasteboard() {
        // Timed private mode (Slice 5): return BEFORE reading the
        // pasteboard. Nothing is evaluated, stored, or recorded as a
        // blocked-event line — guaranteed structurally, not by filtering.
        if settings.isPrivateModeActive {
            captureGateWasActive = true
            return
        }
        if settings.privateModeUntil != nil {
            // Private mode just expired on its own: clear it and resync
            // the dedup state WITHOUT ingesting so the last item copied
            // while private is never retro-captured.
            settings.privateModeUntil = nil
            try? settingsStore.save(settings)
            resyncPasteboardStateWithoutIngesting()
            captureGateWasActive = false
            lastStatus = "Private mode ended"
            configureStatusIcon()
            rebuildMenu()
        }

        if settings.isTemporarilyPaused {
            isPaused = true
            captureGateWasActive = true
            configureStatusIcon()
            return
        } else if isPaused, settings.pauseUntil != nil {
            settings.pauseUntil = nil
            try? settingsStore.save(settings)
            isPaused = false
            // FIX (pre-existing privacy bug): without this resync the last
            // item copied DURING the pause was retro-captured on resume.
            resyncPasteboardStateWithoutIngesting()
            captureGateWasActive = false
            configureStatusIcon()
            lastStatus = "Capture resumed"
            rebuildMenu()
        }

        guard !isPaused else {
            captureGateWasActive = true
            return
        }

        if captureGateWasActive {
            // First ungated poll after ANY gate (manual pause end handles
            // its own resync too, but this is the safety net for every
            // exit path): sync dedup state, ingest nothing this pass.
            captureGateWasActive = false
            resyncPasteboardStateWithoutIngesting()
            return
        }

        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }
        lastChangeCount = changeCount

        // Rich classification (Slice 6) runs only AFTER every capture gate
        // above allowed reading the pasteboard, and only when the setting
        // is on; otherwise the original text-only read is unchanged.
        guard let read = readCaptureFromPasteboard() else {
            return
        }

        guard settings.archiveEnabled else {
            lastStatus = "Archive off \(shortDate(Date()))"
            rebuildMenu()
            return
        }

        // Per-kind dedup shared with every copy-back path (Slice 6).
        let dedupValue = ClipboardCaptureDedup.value(content: read.content, rich: read.rich)
        guard dedupValue != lastContentHash else {
            return
        }
        lastContentHash = dedupValue

        let sourceApp = detectedSourceApp()
        let capture = ClipboardCapture(
            capturedAt: Date(),
            content: read.content,
            sourceApp: sourceApp,
            pasteboardTypes: pasteboard.types?.map(\.rawValue) ?? [],
            rich: read.rich
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
            case let .blocked(reason):
                blockedCount += 1
                lastBlockedReason = reason
                // Cap-blocked images are a size decision, not a sensitivity
                // one — the status wording keys off the reason prefix.
                lastStatus = reason.hasPrefix("image_exceeds_size_cap")
                    ? "Image too large to store \(shortDate(Date()))"
                    : "Blocked sensitive item \(shortDate(Date()))"
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
        if !isPaused {
            // FIX (pre-existing privacy bug): resuming from a manual pause
            // must not retro-capture the last item copied while paused.
            resyncPasteboardStateWithoutIngesting()
            captureGateWasActive = false
        }
        configureStatusIcon()
        lastStatus = isPaused ? "Paused by user" : "Capture resumed"
        rebuildMenu()
    }

    /// The one gate-exit resync (Slice 5): aligns the capture dedup state
    /// with the CURRENT pasteboard without ingesting, so whatever was
    /// copied during private mode or a pause never becomes an archive
    /// event. Only a NEW copy (a fresh change count) captures afterwards.
    /// Uses the SAME classification + dedup derivation as the capture poll
    /// (Slice 6) so rich content copied during a gate is also never
    /// retro-captured.
    private func resyncPasteboardStateWithoutIngesting() {
        lastChangeCount = pasteboard.changeCount
        lastContentHash = readCaptureFromPasteboard().map {
            ClipboardCaptureDedup.value(content: $0.content, rich: $0.rich)
        }
    }

    // MARK: - Rich pasteboard classification (Slice 6)

    private struct PasteboardRead {
        var content: String
        var rich: ClipboardRichPayload?
    }

    /// One pasteboard read for the capture poll: rich classification when
    /// the setting is on, otherwise the original text-only read unchanged.
    /// `content` is ALWAYS the plain-text fallback (empty for images) —
    /// the filter/secret-detector/FTS substrate.
    private func readCaptureFromPasteboard() -> PasteboardRead? {
        if settings.captureRichContent, let rich = readRichPayload() {
            return rich
        }
        guard let content = pasteboard.string(forType: .string), !content.isEmpty else {
            return nil
        }
        return PasteboardRead(content: content, rich: nil)
    }

    /// Rich classification priority (design): fileURL > png/tiff > rtf >
    /// color > public.url+url-name > plain string. Returns nil when no rich
    /// representation applies (the caller falls through to plain text).
    private func readRichPayload() -> PasteboardRead? {
        guard let types = pasteboard.types, !types.isEmpty else {
            return nil
        }

        // 1. File references: metadata ONLY, never file contents.
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL],
           !urls.isEmpty {
            let files = urls.map { url -> ClipboardRichFileReference in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                return ClipboardRichFileReference(
                    name: url.lastPathComponent,
                    path: url.path,
                    byteCount: (attributes?[.size] as? NSNumber)?.intValue,
                    uti: UTType(filenameExtension: url.pathExtension)?.identifier
                )
            }
            return PasteboardRead(
                content: files.map(\.path).joined(separator: "\n"),
                rich: .fileList(files)
            )
        }

        // 2. Images: size check on data.count BEFORE any header parse —
        //    an over-cap payload is never decoded, not even for dimensions.
        for (type, uti) in [
            (NSPasteboard.PasteboardType.png, "public.png"),
            (NSPasteboard.PasteboardType.tiff, "public.tiff")
        ] where types.contains(type) {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else {
                continue
            }
            var pixelWidth: Int?
            var pixelHeight: Int?
            if data.count <= settings.richImageMaxBytes,
               let source = CGImageSourceCreateWithData(
                   data as CFData,
                   [kCGImageSourceShouldCache: false] as CFDictionary
               ),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                // Header-only parse: dimensions without a pixel decode.
                pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
                pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            }
            return PasteboardRead(
                content: "",
                rich: .image(data: data, uti: uti, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            )
        }

        // 3. RTF with its plain-text fallback (secret-detector substrate).
        if types.contains(.rtf), let data = pasteboard.data(forType: .rtf), !data.isEmpty {
            let fallback = pasteboard.string(forType: .string)
                ?? NSAttributedString(rtf: data, documentAttributes: nil)?.string
                ?? ""
            return PasteboardRead(content: fallback, rich: .rtf(data: data))
        }

        // 4. Colors.
        if types.contains(.color), let color = NSColor(from: pasteboard),
           let converted = color.usingColorSpace(.sRGB) {
            let hex = String(
                format: "#%02X%02X%02X",
                Int(round(converted.redComponent * 255)),
                Int(round(converted.greenComponent * 255)),
                Int(round(converted.blueComponent * 255))
            )
            return PasteboardRead(content: hex, rich: .color(hex: hex, colorSpace: "sRGB"))
        }

        // 5. Titled links: BOTH public.url and public.url-name present.
        //    Untitled URLs stay on the plain string path (the writer's
        //    text-based URL inference is unchanged).
        let urlNameType = NSPasteboard.PasteboardType("public.url-name")
        if types.contains(.URL), types.contains(urlNameType),
           let url = pasteboard.string(forType: .URL), !url.isEmpty,
           let title = pasteboard.string(forType: urlNameType), !title.isEmpty {
            return PasteboardRead(content: url + "\n" + title, rich: .link(url: url, title: title))
        }

        return nil
    }

    // MARK: - Timed private mode (Slice 5)

    @objc private func privateMode15Minutes() {
        startPrivateMode(until: Date().addingTimeInterval(15 * 60))
    }

    @objc private func privateModeOneHour() {
        startPrivateMode(until: Date().addingTimeInterval(60 * 60))
    }

    @objc private func privateModeUntilTomorrow() {
        let tomorrow = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        )
        startPrivateMode(until: tomorrow)
    }

    private func startPrivateMode(until: Date) {
        settings.privateModeUntil = until
        try? settingsStore.save(settings)
        captureGateWasActive = true
        lastStatus = "Private until \(shortTime(until))"
        configureStatusIcon()
        rebuildMenu()
    }

    @objc private func endPrivateMode() {
        settings.privateModeUntil = nil
        try? settingsStore.save(settings)
        // Manual exit uses the same resync rule as expiry: nothing copied
        // while private is retro-captured.
        resyncPasteboardStateWithoutIngesting()
        captureGateWasActive = false
        lastStatus = "Private mode ended"
        configureStatusIcon()
        rebuildMenu()
    }

    // MARK: - Expiry enforcement (Slice 5)

    /// Cheap due-check (one annotations stat) and, only when due, a
    /// background sweep. Wired to launch, the 30-minute timer, and surface
    /// opens — NEVER the capture poll.
    private func sweepExpiredIfDue() {
        let sweeper = ClipboardExpirySweeper(archiveRoot: archiveRoot)
        guard let due = sweeper.nextDue(), due <= Date() else {
            return
        }
        DispatchQueue.global(qos: .utility).async { @Sendable [weak self] in
            let result = try? sweeper.sweepIfDue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let result, result.sweptContentHashes > 0 else {
                        return
                    }
                    self.markQuickPickerCacheDirty()
                    self.liveEventCountEstimate = nil
                    self.lastStatus = "Removed \(result.deletedEvents) expired clip\(result.deletedEvents == 1 ? "" : "s")"
                    self.panelController?.reloadFromExternalMutation()
                    self.rebuildMenu()
                }
            }
        }
    }

    // MARK: - Storage & Health dashboard (Slice 5)

    @objc private func openDashboard() {
        sweepExpiredIfDue()
        if dashboardWindowController == nil {
            dashboardWindowController = ClipboardDashboardWindowController(
                archiveRoot: archiveRoot,
                onArchiveMutated: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.markQuickPickerCacheDirty()
                    self.liveEventCountEstimate = nil
                    self.panelController?.reloadFromExternalMutation()
                    self.rebuildMenu()
                }
            )
        }
        dashboardWindowController?.show(activate: true)
    }

    // MARK: - Encrypted backup/restore (Slice 8)

    private var backupUIController: ClipboardBackupUIController?

    private func backupController() -> ClipboardBackupUIController {
        if let backupUIController {
            return backupUIController
        }
        let controller = ClipboardBackupUIController(
            archiveRoot: archiveRoot,
            onArchiveMutated: { [weak self] in
                guard let self else {
                    return
                }
                // Post-import archive-mutation hook: same invalidations as
                // every other external archive mutation.
                self.markQuickPickerCacheDirty()
                self.liveEventCountEstimate = nil
                self.panelController?.reloadFromExternalMutation()
                self.rebuildMenu()
            }
        )
        backupUIController = controller
        return controller
    }

    @objc private func backupArchive() {
        backupController().runBackup()
    }

    @objc private func restoreFromBackup() {
        backupController().runRestore()
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
        // Lazy expiry check on surface open (Slice 5 enforcement point).
        sweepExpiredIfDue()
        if panelController == nil {
            panelController = ClipboardPanelController(
                archiveRoot: archiveRoot,
                recentItemLimit: settings.recentItemLimit,
                historyWindow: settings.historyWindow,
                groupDuplicates: settings.historyGroupDuplicates,
                copyEventToPasteboard: { [weak self] event in
                    // Event-based copy-back (Slice 6): original rich
                    // representations through the ONE no-re-capture path.
                    self?.copyEventToPasteboardWithoutRecapture(event)
                },
                copyPlainTextToPasteboard: { [weak self] content in
                    // Multi-select joins stay plain text (documented).
                    self?.copyToPasteboardWithoutRecapture(content)
                },
                onArchiveMutation: { [weak self] mutation in
                    guard let self else {
                        return
                    }
                    // Every panel mutation invalidates the picker's warm
                    // caches: a stale in-memory event still carries
                    // contentInline (deleted content must never resurrect
                    // via copy-back), and pins/snippets may have changed.
                    self.markQuickPickerCacheDirty()
                    if case .annotationsChanged(pinRemoved: true) = mutation {
                        // Unpinning shrinks the retention-exempt set, so
                        // the in-memory counted estimate could undercount
                        // and silently stop enforcing retention. Reset it
                        // for one reseed scan. (Pinning only overestimates,
                        // which is safe — no reset needed.)
                        self.liveEventCountEstimate = nil
                    }
                },
                onGroupDuplicatesChanged: { [weak self] enabled in
                    guard let self else {
                        return
                    }
                    self.settings.historyGroupDuplicates = enabled
                    try? self.settingsStore.save(self.settings)
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
        // Lazy expiry check on surface open (Slice 5 enforcement point).
        sweepExpiredIfDue()
        if quickPickerController == nil {
            quickPickerController = QuickPickerPanelController(
                dependencies: QuickPickerPanelController.Dependencies(
                    loadEvents: { [weak self] in
                        self?.quickPickerEvents() ?? []
                    },
                    loadSnippets: { [weak self] in
                        self?.quickPickerSnippets() ?? []
                    },
                    copyToPasteboard: { [weak self] event in
                        // Wraps the ONE shared no-re-capture copy path
                        // (event-based since Slice 6: rich events restore
                        // their original representations).
                        guard let self,
                              let content = try? self.reader.content(for: event) else {
                            return nil
                        }
                        self.copyEventToPasteboardWithoutRecapture(event)
                        return content
                    },
                    commitSnippet: { [weak self] snippet in
                        // Commit-time resolution (contract 5): newest live
                        // occurrence → content → the ONE shared
                        // no-re-capture copy path.
                        guard let self,
                              let event = self.resolveNewestLiveOccurrence(
                                  contentHash: snippet.contentHash
                              ),
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
        snippetCacheDirty = true
    }

    /// Snippet entries for the picker's top section: title + load-time
    /// enablement (commit re-resolves). Cached beside the event cache.
    private func quickPickerSnippets() -> [QuickPickerPanelController.SnippetItem] {
        if !snippetCacheDirty {
            return snippetCache
        }
        snippetCache = annotationsStore.snippets().map { entry in
            let resolved = resolveNewestLiveOccurrence(contentHash: entry.contentHash)
            let title = entry.record.snippetTitle
                ?? resolved.map { trimmedPreview($0.contentPreview) }
                ?? "Snippet"
            return QuickPickerPanelController.SnippetItem(
                contentHash: entry.contentHash,
                title: title,
                hasLiveOccurrence: resolved != nil
            )
        }
        snippetCacheDirty = false
        return snippetCache
    }

    /// Newest live occurrence of a content hash: resolver ids (newest
    /// first, suppression-filtered) → the first that still fetches by id.
    private func resolveNewestLiveOccurrence(contentHash: String) -> StoredClipboardEvent? {
        guard let ids = try? occurrenceResolver.liveOccurrenceIDs(contentHash: contentHash) else {
            return nil
        }
        for id in ids {
            if let event = try? reader.event(withID: id) {
                return event
            }
        }
        return nil
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
            controller.onOpenDashboard = { [weak self] in
                self?.openDashboard()
            }
            controller.onBackupArchive = { [weak self] in
                self?.backupArchive()
            }
            controller.onRestoreArchive = { [weak self] in
                self?.restoreFromBackup()
            }
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
            derivedIndex: derivedIndex,
            richImageMaxBytes: settings.richImageMaxBytes
        )
        if previousInterval != settings.pollIntervalSeconds {
            restartTimer()
        }
        markQuickPickerCacheDirty()
        let failureBeforeSave = shortcutFailureMessage
        applyQuickPickerShortcut()
        lastStatus = settings.archiveEnabled ? "Settings saved" : "Archive tracking off"
        rebuildMenu()
        // The settings window hides itself right after save, so a
        // registration failure discovered here needs its own visible
        // surface, not just the (now hidden) conflict label. Alert only on
        // a NEW failure — an unrelated save while an old conflict persists
        // must not nag (the persistent menu item already covers it).
        if let shortcutFailureMessage, shortcutFailureMessage != failureBeforeSave {
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
            hasCompletedOnboarding: true,
            // Rules-card render fixture: one explicit store-no-index rule
            // beside the legacy Block entry above.
            appPrivacyRules: [
                "com.example.crm": ClipboardAppPrivacyRule(
                    mode: ClipboardAppPrivacyRule.storeNoIndexMode,
                    addedAt: Date(timeIntervalSince1970: 1_800_000_000)
                )
            ]
        )

        do {
            try settingsStore.save(settings)
            if screen == "history" {
                if environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RETENTION_FLOW"] == "pin-prune" {
                    // Pin→prune→survives receipt: this flow is the ONLY
                    // seeding (14 events, pin the 2 oldest, enforce a
                    // limit of 10) so the counts in the receipt are exact.
                    try runPinPruneRetentionFlow()
                } else if environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_RICH"] == "1" {
                    // Rich-format render receipts (Slice 6): ONLY the five
                    // per-kind rich fixtures, newest-first image→link.
                    try seedSyntheticRichFixtures()
                } else {
                    try seedSyntheticUIFixtures()
                }
                if let duplicateSeed = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_DUPLICATES"],
                   let duplicateCount = Int(duplicateSeed), duplicateCount > 1 {
                    try seedDuplicateFixtures(count: duplicateCount)
                }
                if environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_ANNOTATIONS_FIXTURE"] == "future-version" {
                    try seedFutureVersionAnnotationsFixture()
                }
                if environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_REBUILD_INDEX"] == "1" {
                    // Restricted receipts need real index rows to prove
                    // they disappear on mark-restricted.
                    _ = try derivedIndex.rebuild()
                }
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
                if environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_GROUP_DUPLICATES"] == "1" {
                    panelController?.performAutomationGroupDuplicates(true)
                }
                if let collectionFilter = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_COLLECTION_FILTER"],
                   !collectionFilter.isEmpty {
                    panelController?.performAutomationCollectionFilter(collectionFilter)
                }
            } else if screen == "settings" {
                showSettingsWindow(activate: false)
            } else if screen == "onboarding" {
                showOnboarding(activate: false)
            } else if screen == "dashboard" {
                try seedSyntheticUIFixtures()
                try seedBlockedEventFixtures()
                _ = try derivedIndex.rebuild()
                openDashboardForAutomation()
            } else if screen == "bulk" {
                try seedBulkFixtures()
                _ = try derivedIndex.rebuild()
                openDashboardForAutomation()
                dashboardWindowController?.performAutomationOpenBulkSheet()
            } else if screen == "privatemode" {
                // No seeding: the receipt proves NOTHING lands in the
                // archive while private, including blocked-event lines.
                runPrivateModeAutomation(snapshotPath: snapshotPath)
                return true
            } else if screen == "richcapture" {
                // Slice 6: synthetic multi-representation items on the
                // isolated automation pasteboard → one poll tick →
                // machine-readable receipt (kind stored, counts, body file,
                // copy-back byte equality, no re-capture).
                runRichCaptureAutomation()
                return true
            } else if screen == "quickpicker" {
                if environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_RICH"] == "1" {
                    try seedSyntheticRichFixtures()
                } else {
                    try seedSyntheticUIFixtures()
                }
                if environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_SNIPPET"] == "1",
                   let newest = try reader.recentItems(since: .distantPast, limit: 1).first {
                    // Snippet fixture for the picker's top section: mark
                    // the newest seeded clip (production store API).
                    try annotationsStore.setSnippet(
                        true,
                        title: "Launch checklist snippet",
                        forContentHash: newest.contentHash
                    )
                }
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
                    guard let self else {
                        return
                    }
                    // Gestures run through production handlers AFTER the
                    // initial state settled, then one capture-poll tick
                    // proves a history copy is never re-captured.
                    let eventCountBefore = self.archiveEventCount()
                    if let gestures = ProcessInfo.processInfo
                        .environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_HISTORY_GESTURES"],
                       !gestures.isEmpty {
                        for gesture in gestures.split(separator: ",") {
                            self.panelController?.performAutomationHistoryGesture(String(gesture))
                        }
                    }
                    if ProcessInfo.processInfo
                        .environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SWEEP_EXPIRED"] == "1" {
                        // Synchronous sweep so the receipt is deterministic;
                        // production wiring uses the same sweeper off-main.
                        let sweep = try? ClipboardExpirySweeper(archiveRoot: archiveRoot)
                            .sweepIfDue()
                        self.automationSweepReceipt = [
                            "sweptHashes": sweep?.sweptContentHashes ?? -1,
                            "deletedEvents": sweep?.deletedEvents ?? -1,
                            "reclaimedBytes": Int(sweep?.reclaimedBytes ?? -1)
                        ]
                        self.panelController?.reloadFromExternalMutation()
                    }
                    // Second settle pass (Slice 6): a gesture can select an
                    // image clip whose detail thumbnail renders async; wait
                    // for it so per-kind detail PNGs show the real render.
                    let postGestureDeadline = Date().addingTimeInterval(5.0)
                    self.pollHistoryAutomationSettled(deadline: postGestureDeadline) { [weak self] in
                        guard let self else {
                            return
                        }
                        self.pollPasteboard()
                        let eventCountAfter = self.archiveEventCount()
                        let url = URL(fileURLWithPath: snapshotPath)
                        do {
                            try self.panelController?.writeSnapshot(to: url)
                        } catch {
                            FileHandle.standardError.write(Data("UI snapshot failed: \(error)\n".utf8))
                        }
                        self.writeHistoryAutomationResult(
                            eventCountBefore: eventCountBefore,
                            eventCountAfter: eventCountAfter
                        )
                        NSApp.terminate(nil)
                    }
                }
            }
            return true
        }

        if screen == "dashboard" {
            let deadline = Date().addingTimeInterval(5.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.pollDashboardAutomationSettled(deadline: deadline) { [weak self] in
                    guard let self else {
                        return
                    }
                    do {
                        try self.dashboardWindowController?.writeSnapshot(
                            to: URL(fileURLWithPath: snapshotPath)
                        )
                    } catch {
                        FileHandle.standardError.write(Data("UI snapshot failed: \(error)\n".utf8))
                    }
                    self.writeDashboardAutomationResult()
                    NSApp.terminate(nil)
                }
            }
            return true
        }

        if screen == "bulk" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.runBulkAutomation(snapshotPath: snapshotPath)
                // NSApp.terminate stalls while a sheet is attached; the
                // receipts are already written atomically, so exit directly.
                exit(0)
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

    private func pollDashboardAutomationSettled(
        deadline: Date,
        completion: @escaping () -> Void
    ) {
        if dashboardWindowController?.automationIsSettled ?? true || Date() >= deadline {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.pollDashboardAutomationSettled(deadline: deadline, completion: completion)
        }
    }

    /// Opens the dashboard without activating the app (never steals focus
    /// from the foreground application).
    private func openDashboardForAutomation() {
        if dashboardWindowController == nil {
            dashboardWindowController = ClipboardDashboardWindowController(
                archiveRoot: archiveRoot,
                onArchiveMutated: { [weak self] in
                    self?.markQuickPickerCacheDirty()
                    self?.liveEventCountEstimate = nil
                }
            )
        }
        dashboardWindowController?.show(activate: false)
    }

    /// Blocked-event fixtures for the dashboard's Recent Blocked Items
    /// section: one per reason family, so the humanized explanations render.
    private func seedBlockedEventFixtures() throws {
        let fixtures: [(reason: String, app: ClipboardSourceApp)] = [
            (
                "source_app_denylist:com.1password.1password",
                ClipboardSourceApp(name: "1Password", bundleIdentifier: "com.1password.1password")
            ),
            (
                "app_rule_block:com.example.crm",
                ClipboardSourceApp(name: "Example CRM", bundleIdentifier: "com.example.crm")
            ),
            (
                "secret_detector:env-secret-assignment",
                ClipboardSourceApp(name: "Terminal", bundleIdentifier: "com.apple.Terminal")
            )
        ]
        for (offset, fixture) in fixtures.enumerated() {
            try archiveWriter.archiveBlockedCapture(
                ClipboardCapture(
                    capturedAt: Date().addingTimeInterval(TimeInterval(-(offset + 1)) * 300),
                    content: "synthetic blocked fixture — content is never stored",
                    sourceApp: fixture.app,
                    pasteboardTypes: ["public.utf8-plain-text"]
                ),
                reason: fixture.reason
            )
        }
    }

    private func writeDashboardAutomationResult() {
        let environment = ProcessInfo.processInfo.environment
        guard let resultPath = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH"],
              !resultPath.isEmpty else {
            return
        }
        let result: [String: Any] = [
            "settled": dashboardWindowController?.automationIsSettled ?? false,
            "healthFacts": dashboardWindowController?.automationHealthFacts ?? [:],
            "blockedExplanations": dashboardWindowController?.automationBlockedExplanations ?? [],
            "cleanupResultText": dashboardWindowController?.automationCleanupResultText ?? "",
            "deleteEnabled": dashboardWindowController?.automationDeleteEnabled ?? false
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: resultPath), options: [.atomic])
        }
    }

    /// Bulk fixtures: 4 old clips (one pinned) + 1 fresh clip, so the
    /// "Older than 7 days" criterion matches exactly the old unpinned ones.
    private func seedBulkFixtures() throws {
        let apps = [
            ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari")
        ]
        var events: [StoredClipboardEvent] = []
        for slot in 0..<4 {
            let event = try archiveWriter.archiveAllowedCapture(
                ClipboardCapture(
                    capturedAt: Date().addingTimeInterval(TimeInterval(-(10 + slot)) * 86_400),
                    content: "synthetic old bulk fixture clip \(slot)",
                    sourceApp: apps[slot % apps.count],
                    pasteboardTypes: ["public.utf8-plain-text"]
                )
            )
            events.append(event)
        }
        _ = try archiveWriter.archiveAllowedCapture(
            ClipboardCapture(
                capturedAt: Date().addingTimeInterval(-120),
                content: "synthetic fresh bulk fixture clip",
                sourceApp: apps[0],
                pasteboardTypes: ["public.utf8-plain-text"]
            )
        )
        if let pinTarget = events.first {
            try annotationsStore.setPinned(true, forContentHash: pinTarget.contentHash)
        }
    }

    /// Drives the bulk sheet through its production automation handlers:
    /// criteria → preview (pinned exempt) → include-pinned toggle (its own
    /// confirm, auto-accepted in automation) → preview → execute. The
    /// receipt proves preview == execute number-for-number.
    private func runBulkAutomation(snapshotPath: String) {
        guard let sheet = dashboardWindowController?.automationBulkSheet else {
            FileHandle.standardError.write(Data("bulk automation: sheet missing\n".utf8))
            return
        }
        // "Older than 7 days".
        sheet.performAutomationDateChoice(1)
        sheet.performAutomationPreview()
        let previewExemptingPinned = sheet.automationLastPreview
        let deleteEnabledAfterPreview = sheet.automationDeleteEnabled
        // Edit invalidates: toggling include-pinned disables Delete until
        // the next preview.
        sheet.performAutomationIncludePinned(true)
        let deleteEnabledAfterEdit = sheet.automationDeleteEnabled
        sheet.performAutomationPreview()
        let previewIncludingPinned = sheet.automationLastPreview
        try? sheet.writeSnapshot(to: URL(fileURLWithPath: snapshotPath))
        sheet.performAutomationDelete()
        let executed = sheet.automationLastExecuted
        let remaining = archiveEventCount()

        let environment = ProcessInfo.processInfo.environment
        guard let resultPath = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH"],
              !resultPath.isEmpty else {
            return
        }
        func facts(_ result: ClipboardBulkResult?) -> [String: Any] {
            guard let result else {
                return [:]
            }
            return [
                "matchedEvents": result.matchedEvents,
                "reclaimedBytes": Int(result.reclaimedBytes),
                "deletedBodyFiles": result.deletedBodyFiles,
                "changedFiles": result.changedFiles,
                "exemptedPinnedEvents": result.exemptedPinnedEvents,
                "removedAnnotationHashes": result.removedAnnotationHashes,
                "dryRun": result.dryRun,
                "reason": result.reason
            ]
        }
        let parity: Bool
        if let preview = previewIncludingPinned, let executed {
            parity = preview.matchedEvents == executed.matchedEvents
                && preview.reclaimedBytes == executed.reclaimedBytes
                && preview.deletedBodyFiles == executed.deletedBodyFiles
                && preview.exemptedPinnedEvents == executed.exemptedPinnedEvents
        } else {
            parity = false
        }
        let result: [String: Any] = [
            "previewExemptingPinned": facts(previewExemptingPinned),
            "previewIncludingPinned": facts(previewIncludingPinned),
            "executed": facts(executed),
            "previewMatchesExecute": parity,
            "deleteEnabledAfterPreview": deleteEnabledAfterPreview,
            "deleteEnabledAfterEdit": deleteEnabledAfterEdit,
            "eventsRemaining": remaining,
            "resultText": sheet.automationResultText
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: resultPath), options: [.atomic])
        }
    }

    /// Private-mode receipt: copies land on the isolated automation
    /// pasteboard DURING private mode, polls run, and the receipt proves
    /// {storedDuring: 0, blockedDuring: 0, storedAfterResume: 0} plus a
    /// normal capture after a genuinely new copy.
    private func runPrivateModeAutomation(snapshotPath: String) {
        _ = snapshotPath
        settings.archiveEnabled = true
        try? settingsStore.save(settings)

        // Enter private mode through the production menu action path.
        startPrivateMode(until: Date().addingTimeInterval(15 * 60))

        // Two copies DURING private mode (isolated pasteboard).
        pasteboard.clearContents()
        pasteboard.setString("private automation secret one", forType: .string)
        pollPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("private automation secret two", forType: .string)
        pollPasteboard()
        let storedDuring = archiveEventCount()
        let blockedDuring = (try? reader.recentBlockedEvents(since: .distantPast, limit: 100).count) ?? -1

        // Exit through the production End Private Mode path (resync), then
        // poll twice: the item copied while private must NOT retro-capture.
        endPrivateMode()
        pollPasteboard()
        pollPasteboard()
        let storedAfterResume = archiveEventCount()

        // A genuinely NEW copy captures normally.
        pasteboard.clearContents()
        pasteboard.setString("post-private ordinary automation copy", forType: .string)
        pollPasteboard()
        let storedAfterNewCopy = archiveEventCount()

        let environment = ProcessInfo.processInfo.environment
        if let resultPath = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH"],
           !resultPath.isEmpty {
            let result: [String: Any] = [
                "storedDuring": storedDuring,
                "blockedDuring": blockedDuring,
                "storedAfterResume": storedAfterResume,
                "storedAfterNewCopy": storedAfterNewCopy,
                "privateModeCleared": settings.privateModeUntil == nil
            ]
            if let data = try? JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: URL(fileURLWithPath: resultPath), options: [.atomic])
            }
        }
        NSApp.terminate(nil)
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
    /// state, row kinds, pin facts, annotations-file facts, no-re-capture
    /// counts, and proof that the drifted and doNotIndex fixtures stayed
    /// invisible.
    private func writeHistoryAutomationResult(
        eventCountBefore: Int = -1,
        eventCountAfter: Int = -1
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let resultPath = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH"],
              !resultPath.isEmpty else {
            return
        }
        let visibleIDs = panelController?.automationVisibleResultIDs ?? []
        let annotationsFileURL = annotationsStore.annotationsFileURL
        let annotationsBytesNow = try? Data(contentsOf: annotationsFileURL)
        var result: [String: Any] = [
            "scope": environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCOPE"] ?? "working",
            "state": panelController?.automationStateName ?? "unknown",
            "settled": panelController?.automationIsSettled ?? false,
            "resultCount": panelController?.automationRowCount ?? -1,
            "visibleIDs": visibleIDs,
            "rowKinds": panelController?.automationRowKinds ?? [],
            "pinnedVisibleIDs": panelController?.automationPinnedVisibleIDs ?? [],
            "statusText": panelController?.automationStatusText ?? "",
            "driftedEventID": automationDriftedEventID,
            "doNotIndexEventID": automationDoNotIndexEventID,
            "driftedEventVisible": !automationDriftedEventID.isEmpty
                && visibleIDs.contains(automationDriftedEventID),
            "doNotIndexEventVisible": !automationDoNotIndexEventID.isEmpty
                && visibleIDs.contains(automationDoNotIndexEventID),
            "eventCountBefore": eventCountBefore,
            "eventCountAfter": eventCountAfter,
            "pasteboardPrefix": String((pasteboard.string(forType: .string) ?? "").prefix(24)),
            "annotationsDirectoryExists": FileManager.default.fileExists(
                atPath: annotationsStore.annotationsDirectoryURL.path
            ),
            "annotationsFileExists": FileManager.default.fileExists(
                atPath: annotationsFileURL.path
            )
        ]
        if !automationRetentionReceipt.isEmpty {
            result["retentionFlow"] = automationRetentionReceipt
        }
        if !automationSweepReceipt.isEmpty {
            result["expirySweep"] = automationSweepReceipt
        }
        // Restricted receipts (Slice 5): badge exposure plus the live index
        // row count for the detail hash (0 after mark-restricted).
        result["restrictedVisibleIDs"] = panelController?.automationRestrictedVisibleIDs ?? []
        result["detailContentHash"] = panelController?.automationDetailContentHash ?? ""
        result["indexRowsForDetailHash"] = panelController?.automationIndexRowCountForDetailHash ?? -1
        result["indexRowsForRestrictedHashes"] = panelController?.automationRestrictedIndexRowCount ?? -1
        result["row0ShowsRestrictedBadge"] = panelController?.automationRow0ShowsRestrictedBadge ?? false
        result["expiringEntries"] = annotationsStore.entriesWithExpiry().count
        if let before = automationAnnotationsBytesBefore {
            result["annotationsFileByteIdentical"] = before == annotationsBytesNow
            result["annotationsBytesBefore"] = before.count
            result["annotationsBytesAfter"] = annotationsBytesNow?.count ?? -1
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: resultPath), options: [.atomic])
        }
    }

    /// Seeds `count` captures of IDENTICAL content (same sha256 content
    /// hash) from alternating apps, minutes apart, for duplicate-grouping
    /// receipts.
    private func seedDuplicateFixtures(count: Int) throws {
        let content = "synthetic duplicate fixture — the same text copied again and again"
        let apps = [
            ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
            ClipboardSourceApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        ]
        for slot in 0..<count {
            _ = try archiveWriter.archiveAllowedCapture(
                ClipboardCapture(
                    capturedAt: Date().addingTimeInterval(TimeInterval(-(slot * 9 + 2)) * 60),
                    content: content,
                    sourceApp: apps[slot % apps.count],
                    pasteboardTypes: ["public.utf8-plain-text"]
                )
            )
        }
    }

    /// Pin→prune→survives flow (contract 5 receipt): seed 14 synthetic
    /// events, pin the 2 OLDEST, run incremental retention enforcement with
    /// a limit of 10, and record the receipt facts. Expected: the 2 pinned
    /// events survive OUTSIDE the limit, the 2 oldest UNPINNED events are
    /// pruned, and 10 unpinned events remain counted.
    private func runPinPruneRetentionFlow() throws {
        var seeded: [StoredClipboardEvent] = []
        for slot in 0..<14 {
            let event = try archiveWriter.archiveAllowedCapture(
                ClipboardCapture(
                    capturedAt: Date().addingTimeInterval(TimeInterval(-(14 - slot)) * 600),
                    content: "synthetic retention fixture clip \(slot) of 14",
                    sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
                    pasteboardTypes: ["public.utf8-plain-text"]
                )
            )
            seeded.append(event)
        }
        let oldestTwo = Array(seeded.prefix(2))
        for event in oldestTwo {
            try annotationsStore.setPinned(true, forContentHash: event.contentHash)
        }
        let result = try ClipboardArchivePruner(archiveRoot: archiveRoot)
            .enforceRetentionLimit(keepingMostRecent: 10, reason: "ui-automation-retention")
        let liveIDs = Set(
            ((try? reader.recentItems(since: .distantPast, limit: 100)) ?? []).map(\.id)
        )
        automationRetentionReceipt = [
            "seededEvents": seeded.count,
            "retainedItemLimit": 10,
            "pinnedEventIDs": oldestTwo.map(\.id),
            "pinnedContentHashes": oldestTwo.map(\.contentHash),
            "liveEvents": result.liveEvents,
            "prunedEvents": result.prunedEvents,
            "exemptPinnedEvents": result.exemptPinnedEvents,
            "keptCountedEvents": result.keptCountedEvents,
            "pinnedEventsSurvived": oldestTwo.allSatisfy { liveIDs.contains($0.id) }
        ]
    }

    /// Writes an annotations.json claiming a NEWER format version (with a
    /// pin on the newest seeded clip plus unknown fields). The store must
    /// read pins, refuse every mutation, and leave the file byte-identical.
    private func seedFutureVersionAnnotationsFixture() throws {
        guard let target = try reader.recentItems(since: .distantPast, limit: 1).first else {
            return
        }
        let json = """
        {
          "annotationsVersion": 2,
          "updatedAt": "2027-01-01T00:00:00Z",
          "futureTopLevelField": { "shape": "unknown" },
          "annotations": {
            "\(target.contentHash)": {
              "pinned": true,
              "pinnedAt": "2027-01-01T00:00:00Z",
              "tags": ["from-the-future"],
              "snippet": false,
              "futureRecordField": 7
            }
          },
          "collections": []
        }
        """
        let directory = annotationsStore.annotationsDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        let data = Data(json.utf8)
        try data.write(to: annotationsStore.annotationsFileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: annotationsStore.annotationsFileURL.path
        )
        automationAnnotationsBytesBefore = data
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

    // MARK: - Rich-format automation (Slice 6)

    /// 1×1 red PNG (~70 bytes) — authored synthetic fixture bytes.
    private static func tinyPNGData() -> Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ) ?? Data()
    }

    private static func tinyRTFData() -> Data {
        Data("{\\rtf1\\ansi {\\b Synthetic bold} rich fixture}".utf8)
    }

    private static let automationURLNameType = NSPasteboard.PasteboardType("public.url-name")

    /// Seeds ONE clip per rich kind (newest first: image, files, rtf,
    /// color, link) through the production writer so history/picker/detail
    /// renders show every kind.
    private func seedSyntheticRichFixtures() throws {
        let now = Date()
        let filesDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-rich-fixture-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        let invoiceURL = filesDirectory.appendingPathComponent("synthetic-invoice.pdf")
        try Data("synthetic invoice fixture".utf8).write(to: invoiceURL)
        let files = [
            ClipboardRichFileReference(
                name: invoiceURL.lastPathComponent,
                path: invoiceURL.path,
                byteCount: 25,
                uti: "com.adobe.pdf"
            ),
            ClipboardRichFileReference(
                name: "missing-notes.txt",
                path: filesDirectory.appendingPathComponent("missing-notes.txt").path,
                byteCount: nil,
                uti: "public.plain-text"
            )
        ]
        let fixtures: [(minutesAgo: TimeInterval, content: String, types: [String], rich: ClipboardRichPayload, app: ClipboardSourceApp)] = [
            (
                2,
                "",
                ["public.png"],
                .image(data: Self.tinyPNGData(), uti: "public.png", pixelWidth: 1, pixelHeight: 1),
                ClipboardSourceApp(name: "Preview", bundleIdentifier: "com.apple.Preview")
            ),
            (
                9,
                files.map(\.path).joined(separator: "\n"),
                ["public.file-url"],
                .fileList(files),
                ClipboardSourceApp(name: "Finder", bundleIdentifier: "com.apple.finder")
            ),
            (
                21,
                "Synthetic bold rich fixture",
                ["public.rtf", "public.utf8-plain-text"],
                .rtf(data: Self.tinyRTFData()),
                ClipboardSourceApp(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
            ),
            (
                34,
                "#3A7BFF",
                ["com.apple.cocoa.pasteboard.color"],
                .color(hex: "#3A7BFF", colorSpace: "sRGB"),
                ClipboardSourceApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")
            ),
            (
                48,
                "https://example.com/rich-link\nRich Link Fixture",
                ["public.url", "public.url-name"],
                .link(url: "https://example.com/rich-link", title: "Rich Link Fixture"),
                ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari")
            )
        ]
        // Append OLDEST first: recentItems derives order from append order
        // within a day file, matching how live capture writes.
        for fixture in fixtures.reversed() {
            _ = try archiveWriter.archiveAllowedCapture(
                ClipboardCapture(
                    capturedAt: now.addingTimeInterval(-fixture.minutesAgo * 60),
                    content: fixture.content,
                    sourceApp: fixture.app,
                    pasteboardTypes: fixture.types,
                    rich: fixture.rich
                )
            )
        }
    }

    /// Synthetic rich-capture matrix: writes one kind's representations to
    /// the isolated automation pasteboard, runs one production poll tick,
    /// then copy-back + a second tick — the receipt proves what was stored,
    /// that the body file exists, byte-equal copy-back, and no re-capture.
    private func runRichCaptureAutomation() {
        let environment = ProcessInfo.processInfo.environment
        let kind = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RICH_CAPTURE"] ?? "image"
        let capBlock = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RICH_CAP_BLOCK"] == "1"
        settings.archiveEnabled = true
        settings.captureRichContent = true
        if capBlock {
            // Clamp floor (64 KiB): the oversized fixture below is ~80 KB.
            settings.richImageMaxBytes = 64 * 1024
        }
        try? settingsStore.save(settings)
        ingestor = ClipboardIngestor(
            filter: ClipboardPrivacyFilter(settings: settings),
            archiveWriter: archiveWriter,
            derivedIndex: derivedIndex,
            richImageMaxBytes: settings.richImageMaxBytes
        )

        var originalData: Data?
        var originalReadType: NSPasteboard.PasteboardType?
        var expectedString: String?
        pasteboard.clearContents()
        switch kind {
        case "image":
            let data: Data
            if capBlock {
                // Random bytes never get decoded: the cap check fires on
                // data.count alone (the receipt proves nothing stored).
                data = Data((0..<80_000).map { _ in UInt8.random(in: 0...255) })
            } else {
                data = Self.tinyPNGData()
            }
            originalData = data
            originalReadType = .png
            pasteboard.setData(data, forType: .png)
        case "files":
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("clipboard-rich-capture-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let invoice = directory.appendingPathComponent("synthetic-invoice.pdf")
            let notes = directory.appendingPathComponent("synthetic-notes.txt")
            try? Data("synthetic invoice".utf8).write(to: invoice)
            try? Data("synthetic notes".utf8).write(to: notes)
            pasteboard.writeObjects([invoice as NSURL, notes as NSURL])
            expectedString = [invoice.path, notes.path].joined(separator: "\n")
        case "rtf":
            let data = Self.tinyRTFData()
            originalData = data
            originalReadType = .rtf
            pasteboard.setData(data, forType: .rtf)
            pasteboard.setString("Synthetic bold rich fixture", forType: .string)
        case "color":
            pasteboard.writeObjects([NSColor(srgbRed: 58.0 / 255, green: 123.0 / 255, blue: 1, alpha: 1)])
            expectedString = "#3A7BFF"
        case "link":
            pasteboard.declareTypes([.URL, Self.automationURLNameType, .string], owner: nil)
            pasteboard.setString("https://example.com/rich-link", forType: .URL)
            pasteboard.setString("Rich Link Fixture", forType: Self.automationURLNameType)
            pasteboard.setString("https://example.com/rich-link", forType: .string)
            expectedString = "https://example.com/rich-link"
        default:
            break
        }

        pollPasteboard()
        let storedEvents = (try? reader.recentItems(since: .distantPast, limit: 10)) ?? []
        let newest = storedEvents.first
        var bodyFileExists = false
        if let bodyPath = newest?.richContent?.bodyPath,
           let bodyURL = try? ClipboardArchivePath.containedURL(
               relativePath: bodyPath,
               archiveRoot: archiveRoot
           ) {
            bodyFileExists = FileManager.default.fileExists(atPath: bodyURL.path)
        }
        // Cap-block receipt: prove NO rich body file exists anywhere.
        let richBodyFilesOnDisk = (FileManager.default.enumerator(
            at: archiveRoot.appendingPathComponent("raw"),
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? [])
            .filter { ["png", "tiff", "rtf", "json"].contains($0.pathExtension) }
            .count
        let blocked = (try? reader.recentBlockedEvents(since: .distantPast, limit: 5)) ?? []

        // Copy-back: original representations + dedup sync, then one more
        // poll tick proves no re-capture.
        var copyBackByteEqual: Bool?
        var pasteboardStringAfterCopyBack = ""
        var eventCountAfterCopyBack = -1
        if let newest {
            copyEventToPasteboardWithoutRecapture(newest)
            if let originalData, let originalReadType {
                copyBackByteEqual = pasteboard.data(forType: originalReadType) == originalData
            } else if let expectedString {
                copyBackByteEqual = pasteboard.string(forType: .string) == expectedString
            }
            pasteboardStringAfterCopyBack = pasteboard.string(forType: .string) ?? ""
            pollPasteboard()
            eventCountAfterCopyBack = archiveEventCount()
        }

        if let resultPath = environment["CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH"],
           !resultPath.isEmpty {
            var result: [String: Any] = [
                "requestedKind": kind,
                "capBlock": capBlock,
                "eventCount": storedEvents.count,
                "kindStored": newest?.contentType.rawValue ?? "",
                "richKind": newest?.richContent?.kind ?? "",
                "preview": newest?.contentPreview ?? "",
                "schemaVersion": newest?.schemaVersion ?? -1,
                "bodyFileExists": bodyFileExists,
                "richBodyFilesOnDisk": richBodyFilesOnDisk,
                "blockedCount": blocked.count,
                "blockedReason": blocked.first?.reason ?? "",
                "eventCountAfterCopyBack": eventCountAfterCopyBack,
                "pasteboardStringPrefix": String(pasteboardStringAfterCopyBack.prefix(48))
            ]
            if let copyBackByteEqual {
                result["copyBackByteEqual"] = copyBackByteEqual
            }
            if let files = newest?.richContent?.files {
                result["fileNames"] = files.map(\.name)
            }
            if let width = newest?.richContent?.imagePixelWidth,
               let height = newest?.richContent?.imagePixelHeight {
                result["pixelSize"] = "\(width)x\(height)"
            }
            if let data = try? JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? data.write(to: URL(fileURLWithPath: resultPath), options: [.atomic])
            }
        }
        NSApp.terminate(nil)
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
            // Estimate semantics (Slice 4): the estimate tracks COUNTED
            // (unpinned) events — pinned clips sit outside the limit, so
            // seeding from keptEvents would let pins consume limit slots
            // in the in-memory check and force needless scans.
            liveEventCountEstimate = result.keptCountedEvents
            if result.prunedEvents > 0 {
                lastStatus = "Kept latest \(limit), pruned \(result.prunedEvents)"
                markQuickPickerCacheDirty()
            }
        } catch {
            lastStatus = "Retention prune failed"
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
        if settings.isPrivateModeActive, let privateUntil = settings.privateModeUntil {
            statusTitle = "Private until \(shortTime(privateUntil))"
        } else if isPaused {
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
        if settings.showBlockedEventStatus, let lastBlockedReason {
            let blockedLine = NSMenuItem(
                title: "Last blocked: \(ClipboardBlockedEventExplainer.shortLabel(for: lastBlockedReason))",
                action: nil,
                keyEquivalent: ""
            )
            blockedLine.isEnabled = false
            blockedLine.toolTip = ClipboardBlockedEventExplainer.explanation(for: lastBlockedReason)
            menu.addItem(blockedLine)
        }
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
        maintenanceSubmenu.addItem(NSMenuItem(title: "Storage & Health…", action: #selector(openDashboard), keyEquivalent: "h"))
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

        // Private Mode (Slice 5): unlike pause, NOTHING is read from the
        // pasteboard while active — no stored events, no blocked-event
        // metadata lines.
        let privateMenu = NSMenuItem(title: "Private Mode", action: nil, keyEquivalent: "")
        privateMenu.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Private mode")
        let privateSubmenu = NSMenu()
        privateSubmenu.addItem(NSMenuItem(title: "For 15 Minutes", action: #selector(privateMode15Minutes), keyEquivalent: ""))
        privateSubmenu.addItem(NSMenuItem(title: "For 1 Hour", action: #selector(privateModeOneHour), keyEquivalent: ""))
        privateSubmenu.addItem(NSMenuItem(title: "Until Tomorrow", action: #selector(privateModeUntilTomorrow), keyEquivalent: ""))
        if settings.isPrivateModeActive {
            privateSubmenu.addItem(.separator())
            privateSubmenu.addItem(NSMenuItem(title: "End Private Mode", action: #selector(endPrivateMode), keyEquivalent: ""))
        }
        privateMenu.submenu = privateSubmenu
        maintenanceSubmenu.addItem(privateMenu)
        maintenanceSubmenu.addItem(NSMenuItem(title: "Refresh Menu", action: #selector(refreshMenu), keyEquivalent: "r"))
        maintenanceSubmenu.addItem(NSMenuItem(title: "Open Archive Folder", action: #selector(openArchiveFolder), keyEquivalent: ""))
        maintenanceSubmenu.addItem(NSMenuItem.separator())
        maintenanceSubmenu.addItem(NSMenuItem(title: "Back Up Archive…", action: #selector(backupArchive), keyEquivalent: ""))
        maintenanceSubmenu.addItem(NSMenuItem(title: "Restore from Backup…", action: #selector(restoreFromBackup), keyEquivalent: ""))
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
              let event = try? reader.recentItems(since: sevenDaysAgo(), limit: 200).first(where: { $0.id == id }) else {
            return
        }

        // Event-based copy (Slice 6): restores original rich
        // representations; plain text is unchanged.
        copyEventToPasteboardWithoutRecapture(event)
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
        lastContentHash = ClipboardCaptureDedup.value(content: content, rich: nil)
        lastChangeCount = pasteboard.changeCount
    }

    /// Event-based copy-back (Slice 6): writes the ORIGINAL rich
    /// representations back to the pasteboard, then syncs the dedup state
    /// using the SAME per-kind `ClipboardCaptureDedup` value the capture
    /// poll computes — so neither the copy-back nor a genuine re-copy of
    /// identical rich content is re-captured. Plain-text events (and any
    /// rich event whose body is unreadable) degrade to the plain path.
    private func copyEventToPasteboardWithoutRecapture(_ event: StoredClipboardEvent) {
        let content = (try? reader.content(for: event)) ?? event.contentPreview
        guard let rich = event.richContent else {
            copyToPasteboardWithoutRecapture(content)
            return
        }

        switch rich.kind {
        case ClipboardRichContent.imageKind:
            guard let data = try? reader.richBody(for: event) else {
                copyToPasteboardWithoutRecapture(content)
                return
            }
            let storedType: NSPasteboard.PasteboardType = rich.bodyType == "public.tiff" ? .tiff : .png
            pasteboard.clearContents()
            pasteboard.setData(data, forType: storedType)
            // Derived second representation for apps that only read the
            // other type. This decode happens only on an explicit copy
            // action, never during browsing.
            if let representation = NSBitmapImageRep(data: data) {
                if storedType == .png, let tiff = representation.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                } else if storedType == .tiff,
                          let png = representation.representation(using: .png, properties: [:]) {
                    pasteboard.setData(png, forType: .png)
                }
            }
            lastContentHash = ClipboardCaptureDedup.value(
                content: "",
                rich: .image(
                    data: data,
                    uti: rich.bodyType ?? "public.png",
                    pixelWidth: rich.imagePixelWidth,
                    pixelHeight: rich.imagePixelHeight
                )
            )

        case ClipboardRichContent.rtfKind:
            guard let data = try? reader.richBody(for: event) else {
                copyToPasteboardWithoutRecapture(content)
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .rtf)
            pasteboard.setString(content, forType: .string)
            lastContentHash = ClipboardCaptureDedup.value(content: content, rich: .rtf(data: data))

        case ClipboardRichContent.fileListKind:
            let files = reader.fileList(for: event)
            guard !files.isEmpty else {
                copyToPasteboardWithoutRecapture(content)
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(files.map { NSURL(fileURLWithPath: $0.path) })
            pasteboard.setString(content, forType: .string)
            lastContentHash = ClipboardCaptureDedup.value(content: content, rich: .fileList(files))

        case ClipboardRichContent.colorKind:
            guard let hex = rich.colorHex, let color = Self.color(fromHex: hex) else {
                copyToPasteboardWithoutRecapture(content)
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects([color])
            pasteboard.setString(hex, forType: .string)
            lastContentHash = ClipboardCaptureDedup.value(
                content: hex,
                rich: .color(hex: hex, colorSpace: rich.colorSpace ?? "sRGB")
            )

        case ClipboardRichContent.linkKind:
            guard let url = rich.linkURL, let title = rich.linkTitle else {
                copyToPasteboardWithoutRecapture(content)
                return
            }
            pasteboard.clearContents()
            pasteboard.declareTypes(
                [.URL, NSPasteboard.PasteboardType("public.url-name"), .string],
                owner: nil
            )
            pasteboard.setString(url, forType: .URL)
            pasteboard.setString(title, forType: NSPasteboard.PasteboardType("public.url-name"))
            pasteboard.setString(url, forType: .string)
            lastContentHash = ClipboardCaptureDedup.value(
                content: content,
                rich: .link(url: url, title: title)
            )

        default:
            // Unknown rich kind from a newer build: plain fallback.
            copyToPasteboardWithoutRecapture(content)
            return
        }
        lastChangeCount = pasteboard.changeCount
    }

    private static func color(fromHex hex: String) -> NSColor? {
        var value = hex
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
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

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
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
        let symbolName: String
        if settings.isPrivateModeActive {
            symbolName = "eye.slash"
        } else if isPaused || !settings.archiveEnabled {
            symbolName = "pause.circle"
        } else {
            symbolName = "doc.on.clipboard"
        }
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipboard Archive") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = isPaused ? "Archive Paused" : "Archive"
        }
        if settings.isPrivateModeActive, let until = settings.privateModeUntil {
            statusItem.button?.toolTip = "Clipboard Archive: private until \(shortTime(until))"
        } else if isPaused {
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
