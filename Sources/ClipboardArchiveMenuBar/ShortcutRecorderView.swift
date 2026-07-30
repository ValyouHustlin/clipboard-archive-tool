import ClipboardArchiveCore
import AppKit
import Foundation

@MainActor
protocol ShortcutRecorderViewDelegate: AnyObject {
    /// Live registration must be suspended while recording so pressing the
    /// current combo re-records it instead of triggering the picker.
    func shortcutRecorderWillBeginRecording(_ view: ShortcutRecorderView)
    func shortcutRecorderDidEndRecording(_ view: ShortcutRecorderView)
    func shortcutRecorder(
        _ view: ShortcutRecorderView,
        didRecord shortcut: ClipboardShortcutSetting
    )
    func shortcutRecorderDidClear(_ view: ShortcutRecorderView)
}

/// Button-like control that records a global shortcut. Recording uses a
/// local `NSEvent` monitor for `.keyDown` and `.flagsChanged` — local
/// monitors see keys before key-equivalent dispatch and avoid field-editor
/// complications entirely. The monitor is removed on every exit path, with a
/// window-close safety net. `fn` is never offered (Carbon cannot register
/// fn combos).
@MainActor
final class ShortcutRecorderView: NSButton {
    weak var recorderDelegate: ShortcutRecorderViewDelegate?

    /// The shortcut being displayed/edited. `nil` keyCode is not modeled —
    /// a cleared shortcut keeps its keys but reports `enabled = false`
    /// through the settings checkbox, so this view treats "no shortcut" as
    /// simply showing the placeholder when `shortcut` is nil.
    var shortcut: ClipboardShortcutSetting? {
        didSet {
            refreshTitle()
        }
    }

    private var isRecording = false
    // nonisolated(unsafe): only ever touched on the main actor; the marker
    // exists so the nonisolated deinit can release them (Swift 6 rule).
    private nonisolated(unsafe) var eventMonitor: Any?
    private nonisolated(unsafe) var windowCloseObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        setAccessibilityLabel("Quick picker shortcut")
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            endRecording()
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            endRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !isRecording else {
            return
        }
        isRecording = true
        recorderDelegate?.shortcutRecorderWillBeginRecording(self)
        refreshTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self else {
                return event
            }
            // Local event monitors fire on the main thread; NSEvent is not
            // Sendable, so route a Sendable "consumed" flag through
            // assumeIsolated instead of the event itself.
            let consumed = MainActor.assumeIsolated {
                self.handleRecordingEvent(event)
            }
            return consumed ? nil : event
        }

        // Safety net: never leave a local monitor behind if the settings
        // window closes mid-recording.
        if let window {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.endRecording()
                }
            }
        }
    }

    private func endRecording() {
        guard isRecording else {
            return
        }
        isRecording = false
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        refreshTitle()
        recorderDelegate?.shortcutRecorderDidEndRecording(self)
    }

    /// Returns true to swallow the event while recording.
    private func handleRecordingEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            refreshTitle(liveModifiers: modifierNames(from: event.modifierFlags))
            return true
        case .keyDown:
            if event.keyCode == 53 { // Esc cancels
                endRecording()
                return true
            }
            if event.keyCode == 51 { // Delete clears (shortcut disabled)
                endRecording()
                recorderDelegate?.shortcutRecorderDidClear(self)
                return true
            }
            let candidate = ClipboardShortcutSetting(
                enabled: shortcut?.enabled ?? false,
                keyCode: Int(event.keyCode),
                modifiers: modifierNames(from: event.modifierFlags)
            )
            guard candidate.isValid else {
                NSSound.beep()
                shake()
                return true
            }
            shortcut = candidate
            endRecording()
            recorderDelegate?.shortcutRecorder(self, didRecord: candidate)
            return true
        default:
            return false
        }
    }

    /// Maps AppKit flags to persisted names. `.function` is deliberately
    /// ignored: Carbon hot keys cannot include fn.
    private func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        var names: [String] = []
        if device.contains(.control) {
            names.append("control")
        }
        if device.contains(.option) {
            names.append("option")
        }
        if device.contains(.shift) {
            names.append("shift")
        }
        if device.contains(.command) {
            names.append("command")
        }
        return names
    }

    private func refreshTitle(liveModifiers: [String] = []) {
        if isRecording {
            if liveModifiers.isEmpty {
                title = "Type shortcut…"
            } else {
                let preview = ClipboardShortcutSetting(
                    enabled: false,
                    keyCode: -1,
                    modifiers: liveModifiers
                )
                // Show just the held modifiers while waiting for the key.
                title = String(preview.displayString.dropLast("Key -1".count)) + "…"
            }
        } else if let shortcut {
            title = shortcut.displayString
        } else {
            title = "Record Shortcut"
        }
    }

    private func shake() {
        guard let layer = layer ?? { wantsLayer = true; return layer }() else {
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -6, 6, -4, 4, 0]
        animation.keyTimes = [0, 0.15, 0.35, 0.55, 0.8, 1]
        animation.duration = 0.3
        animation.isAdditive = true
        layer.add(animation, forKey: "shake")
    }
}
