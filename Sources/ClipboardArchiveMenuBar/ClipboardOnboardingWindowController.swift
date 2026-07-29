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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Clipboard Archive"
        window.minSize = NSSize(width: 620, height: 340)
        super.init(window: window)
        buildUI(archiveRoot: archiveRoot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "Choose what this Mac remembers")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        root.addArrangedSubview(title)

        let explanation = wrappingLabel(
            "Clipboard Archive stores accepted clipboard text as plaintext on this Mac. " +
            "It blocks known password-manager apps and obvious credentials, but no filter catches everything."
        )
        root.addArrangedSubview(explanation)

        let pathTitle = NSTextField(labelWithString: "Archive location")
        pathTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        pathTitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(pathTitle)

        let path = wrappingLabel(archiveRoot.path)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.textColor = .secondaryLabelColor
        root.addArrangedSubview(path)

        let guidance = wrappingLabel(
            "Recommended: keep the latest 50 items while you learn the app. " +
            "You can switch to a full archive, pause capture, add exclusions, or delete stored content at any time."
        )
        root.addArrangedSubview(guidance)
        root.addArrangedSubview(NSView())

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let notNow = NSButton(title: "Not Now", target: self, action: #selector(chooseNotNow))
        let fullArchive = NSButton(title: "Use Full Archive", target: self, action: #selector(chooseFullArchive))
        let recent = NSButton(title: "Keep Last 50", target: self, action: #selector(chooseRecent50))
        notNow.tag = 101
        fullArchive.tag = 102
        recent.tag = 103
        recent.keyEquivalent = "\r"

        buttons.addArrangedSubview(notNow)
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(fullArchive)
        buttons.addArrangedSubview(recent)
        root.addArrangedSubview(buttons)
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
