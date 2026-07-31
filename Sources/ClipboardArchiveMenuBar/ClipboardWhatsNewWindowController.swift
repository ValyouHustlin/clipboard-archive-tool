import AppKit
import ClipboardArchiveCore

/// Standard titled window that also dismisses on Esc (the close box and the
/// Done button already cover mouse users). Never floating; never steals
/// key handling from controls inside it.
private final class ClipboardWhatsNewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }

    override func keyDown(with event: NSEvent) {
        // 53 = Esc. cancelOperation covers the usual routing; this covers
        // the bare-window case where no responder claims the key.
        if event.keyCode == 53 {
            orderOut(nil)
            return
        }
        super.keyDown(with: event)
    }
}

/// Post-install / post-upgrade "What's New" surface: one compact window of
/// feature rows with deep links into the surfaces they describe. Shown once
/// per app version (decision: `ClipboardWhatsNew.shouldShow`), and as an
/// optional second step after first-run onboarding. Presentation only — the
/// app delegate owns persistence and injects the deep-link closures, same
/// pattern as every other controller (no new singletons).
@MainActor
final class ClipboardWhatsNewWindowController: NSWindowController {
    /// Deep links, owned by the app delegate.
    var onOpenSettings: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenDashboard: (() -> Void)?

    private var doneButton: NSButton?

    init(appVersion: String) {
        let window = ClipboardWhatsNewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "What's New in Clipboard Archive \(appVersion)"
        window.minSize = NSSize(width: 560, height: 540)
        super.init(window: window)
        buildUI(appVersion: appVersion)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(activate: Bool = true) {
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
        // Appearance-resolved background fill for faithful light/dark
        // snapshots (Slice 9; see ClipboardPanelController.writeSnapshot).
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

    func performAutomationDone() {
        doneButton?.performClick(nil)
    }
#endif

    private func buildUI(appVersion: String) {
        guard let contentView = window?.contentView else {
            return
        }

        // Header band: same adaptive accent wash as the Settings header so
        // light/dark both re-resolve correctly.
        let header = AdaptiveBackgroundView {
            NSColor.controlAccentColor.withAlphaComponent(0.09)
        }
        header.translatesAutoresizingMaskIntoConstraints = false

        let mark = iconTile(symbol: "sparkles", tint: .systemBlue, size: 44)
        let eyebrow = NSTextField(labelWithString: "WHAT'S NEW")
        eyebrow.font = .systemFont(ofSize: 10, weight: .bold)
        eyebrow.textColor = .controlAccentColor
        let title = NSTextField(labelWithString: "Clipboard Archive \(appVersion)")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        let subtitle = NSTextField(
            labelWithString: "Here's what your clipboard can do now — all of it on this Mac."
        )
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let headerText = NSStackView(views: [eyebrow, title, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2
        let headerRow = NSStackView(views: [mark, headerText])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 14
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerRow)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.translatesAutoresizingMaskIntoConstraints = false

        let features: [(symbol: String, tint: NSColor, name: String, detail: String, action: (title: String, selector: Selector, accessibility: String)?)] = [
            (
                "keyboard",
                .systemOrange,
                "Quick Picker",
                "Summon your recent clips over any app with a global shortcut — turn it on in Settings.",
                ("Enable Shortcut…", #selector(openSettingsClicked), "Open Settings to enable the quick picker shortcut")
            ),
            (
                "magnifyingglass",
                .systemPurple,
                "All History Search",
                "Search everything you've ever kept, with date, app, and type filters.",
                ("Open History", #selector(openHistoryClicked), "Open the History window")
            ),
            (
                "pin.fill",
                .systemBlue,
                "Pins & Snippets",
                "Pin keepers so pruning never touches them, and save snippets for instant reuse.",
                nil
            ),
            (
                "eye.slash",
                .systemIndigo,
                "Private Mode & App Privacy Rules",
                "Pause all capture for a while, or set per-app rules that block or hide clips.",
                nil
            ),
            (
                "lock.shield",
                .systemGreen,
                "Encrypted Backup",
                "Save your whole archive as one passphrase-encrypted file and restore it anywhere.",
                nil
            ),
            (
                "internaldrive.fill",
                .systemTeal,
                "Storage & Health",
                "See what's stored, verify integrity, and clean up in bulk with a truthful preview.",
                ("Storage & Health…", #selector(openDashboardClicked), "Open the Storage & Health dashboard")
            )
        ]
        for feature in features {
            rows.addArrangedSubview(featureRow(feature))
        }

        let separator = AdaptiveBackgroundView {
            .separatorColor
        }
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let footerLine = NSTextField(
            labelWithString: "Everything is off until you turn it on. Local-only, as always."
        )
        footerLine.font = .systemFont(ofSize: 11)
        footerLine.textColor = .secondaryLabelColor
        footerLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let done = NSButton(title: "Done", target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.setAccessibilityLabel("Close the What's New window")
        doneButton = done
        let footer = NSStackView(views: [footerLine, NSView(), done])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let body = NSStackView(views: [rows, separator, footer])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.edgeInsets = NSEdgeInsets(top: 18, left: 28, bottom: 20, right: 28)
        body.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(header)
        contentView.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            header.topAnchor.constraint(equalTo: contentView.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 96),
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 28),
            headerRow.trailingAnchor.constraint(
                lessThanOrEqualTo: header.trailingAnchor,
                constant: -28
            ),
            headerRow.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        // Full-width rows/footer under the leading alignment (insets 28+28).
        for view in [rows, separator, footer] {
            view.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -56).isActive = true
        }
    }

    private func featureRow(
        _ feature: (symbol: String, tint: NSColor, name: String, detail: String, action: (title: String, selector: Selector, accessibility: String)?)
    ) -> NSView {
        let icon = iconTile(symbol: feature.symbol, tint: feature.tint, size: 30)

        let name = NSTextField(labelWithString: feature.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: feature.detail)
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        row.addArrangedSubview(icon)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        if let action = feature.action {
            let button = NSButton(title: action.title, target: self, action: action.selector)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.setAccessibilityLabel(action.accessibility)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }
        return row
    }

    private func iconTile(symbol: String, tint: NSColor, size: CGFloat) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = tint.cgColor
        tile.layer?.cornerRadius = size * 0.24
        tile.translatesAutoresizingMaskIntoConstraints = false
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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

    @objc private func openSettingsClicked() {
        onOpenSettings?()
    }

    @objc private func openHistoryClicked() {
        onOpenHistory?()
    }

    @objc private func openDashboardClicked() {
        onOpenDashboard?()
    }

    @objc private func doneClicked() {
        window?.orderOut(nil)
    }
}
