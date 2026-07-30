import AppKit
import ClipboardArchiveCore

@MainActor
protocol ClipboardOnboardingWindowControllerDelegate: AnyObject {
    func clipboardOnboardingWindow(
        _ controller: ClipboardOnboardingWindowController,
        didChooseArchiveEnabled archiveEnabled: Bool,
        retentionMode: ClipboardRetentionMode
    )
}

@MainActor
final class ClipboardOnboardingWindowController: NSWindowController {
    weak var delegate: ClipboardOnboardingWindowControllerDelegate?

    init(archiveRoot: URL) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Clipboard Archive"
        window.minSize = NSSize(width: 680, height: 540)
        super.init(window: window)
        buildUI(archiveRoot: archiveRoot)
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

    func performAutomationChoice(_ choice: String) {
        let tag: Int
        switch choice {
        case "recent-50":
            tag = 103
        case "full-archive":
            tag = 102
        case "not-now":
            tag = 101
        default:
            return
        }
        (window?.contentView?.viewWithTag(tag) as? NSButton)?.performClick(nil)
    }
#endif

    private func buildUI(archiveRoot: URL) {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        // Leading alignment (Slice 9 layout QA): the default centerX made
        // every block float centered at intrinsic width.
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 28, right: 32)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 16
        header.alignment = .top
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "doc.on.clipboard.fill",
            accessibilityDescription: "Clipboard Archive"
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let headings = NSStackView()
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = 5
        let title = NSTextField(labelWithString: "Make your clipboard useful again")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = wrappingLabel(
            "Find text, links, and code you copied recently—without sending any of it off this Mac."
        )
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        headings.addArrangedSubview(title)
        headings.addArrangedSubview(subtitle)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(headings)
        root.addArrangedSubview(header)

        let privacyBox = NSVisualEffectView()
        privacyBox.material = .contentBackground
        privacyBox.blendingMode = .withinWindow
        privacyBox.state = .active
        privacyBox.wantsLayer = true
        privacyBox.layer?.cornerRadius = 10
        let privacyStack = NSStackView()
        privacyStack.orientation = .vertical
        privacyStack.alignment = .leading
        privacyStack.spacing = 5
        privacyStack.edgeInsets = NSEdgeInsets(top: 13, left: 15, bottom: 13, right: 15)
        privacyStack.translatesAutoresizingMaskIntoConstraints = false
        let privacyTitle = NSTextField(labelWithString: "Private by design")
        privacyTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let privacyText = wrappingLabel(
            "History is plain text on this Mac. Clipboard Archive blocks known password-manager apps and obvious credentials, but you should still exclude sensitive apps."
        )
        privacyText.font = .systemFont(ofSize: 12)
        privacyText.textColor = .secondaryLabelColor
        privacyStack.addArrangedSubview(privacyTitle)
        privacyStack.addArrangedSubview(privacyText)
        privacyBox.addSubview(privacyStack)
        NSLayoutConstraint.activate([
            privacyStack.leadingAnchor.constraint(equalTo: privacyBox.leadingAnchor),
            privacyStack.trailingAnchor.constraint(equalTo: privacyBox.trailingAnchor),
            privacyStack.topAnchor.constraint(equalTo: privacyBox.topAnchor),
            privacyStack.bottomAnchor.constraint(equalTo: privacyBox.bottomAnchor),
            privacyBox.heightAnchor.constraint(equalToConstant: 84)
        ])
        root.addArrangedSubview(privacyBox)

        // Compact capabilities line (Slice 9): honest mention of what the
        // app can do without lengthening the flow — still one decision,
        // still the same three choices below.
        let capabilities = NSStackView()
        capabilities.orientation = .vertical
        capabilities.alignment = .leading
        capabilities.spacing = 3
        let capabilitiesTitle = NSTextField(labelWithString: "Also included, when you want it")
        capabilitiesTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let capabilitiesText = wrappingLabel(
            "Quick picker on a global shortcut (enable in Settings) · full-history search · pins, tags, and collections · per-app privacy rules · private mode · encrypted local backups. Everything stays on this Mac."
        )
        capabilitiesText.font = .systemFont(ofSize: 11)
        capabilitiesText.textColor = .secondaryLabelColor
        capabilities.addArrangedSubview(capabilitiesTitle)
        capabilities.addArrangedSubview(capabilitiesText)
        root.addArrangedSubview(capabilities)

        let choiceTitle = NSTextField(labelWithString: "How much should Clipboard Archive remember?")
        choiceTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        root.addArrangedSubview(choiceTitle)

        let choices = NSStackView()
        choices.orientation = .horizontal
        choices.distribution = .fillEqually
        choices.spacing = 12

        let notNow = choiceCard(
            title: "Not Now",
            detail: "Explore settings first.",
            buttonTitle: "Keep Capture Off",
            action: #selector(chooseNotNow),
            buttonTag: 101
        )
        let fullArchive = choiceCard(
            title: "Full Archive",
            detail: "Keep accepted clips until you delete them.",
            buttonTitle: "Use Full Archive",
            action: #selector(chooseFullArchive),
            buttonTag: 102
        )
        let recent = choiceCard(
            title: "Last 50",
            detail: "A low-risk way to start.",
            buttonTitle: "Keep Last 50",
            action: #selector(chooseRecent50),
            buttonTag: 103,
            emphasized: true
        )
        choices.addArrangedSubview(notNow)
        choices.addArrangedSubview(fullArchive)
        choices.addArrangedSubview(recent)
        root.addArrangedSubview(choices)

        let location = NSTextField(labelWithString: "Stored locally: \(archiveRoot.path)")
        location.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        location.textColor = .tertiaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(location)

        // Full-width rows under the leading alignment (insets 32 + 32).
        for view in [header, privacyBox, capabilities, choices] {
            view.widthAnchor.constraint(
                equalTo: root.widthAnchor,
                constant: -64
            ).isActive = true
        }
        headings.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func choiceCard(
        title: String,
        detail: String,
        buttonTitle: String,
        action: Selector,
        buttonTag: Int,
        emphasized: Bool = false
    ) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.borderColor = emphasized ? .controlAccentColor : .separatorColor
        box.cornerRadius = 9

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailLabel = wrappingLabel(detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.tag = buttonTag
        button.bezelStyle = .rounded
        button.setAccessibilityLabel(buttonTitle)
        button.toolTip = detail
        if emphasized {
            button.keyEquivalent = "\r"
        }
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(button)
        box.contentView?.addSubview(stack)
        if let boxContent = box.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: boxContent.trailingAnchor),
                stack.topAnchor.constraint(equalTo: boxContent.topAnchor),
                stack.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor)
            ])
        }
        box.heightAnchor.constraint(equalToConstant: 136).isActive = true
        return box
    }

    private func wrappingLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        return label
    }

    @objc private func chooseRecent50() {
        finish(archiveEnabled: true, retentionMode: .recent50)
    }

    @objc private func chooseFullArchive() {
        finish(archiveEnabled: true, retentionMode: .unlimited)
    }

    @objc private func chooseNotNow() {
        finish(archiveEnabled: false, retentionMode: .recent50)
    }

    private func finish(archiveEnabled: Bool, retentionMode: ClipboardRetentionMode) {
        delegate?.clipboardOnboardingWindow(
            self,
            didChooseArchiveEnabled: archiveEnabled,
            retentionMode: retentionMode
        )
        window?.orderOut(nil)
    }
}
