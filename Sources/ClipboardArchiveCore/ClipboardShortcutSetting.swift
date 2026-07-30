import Foundation

/// One configurable global shortcut (expansion contract 8). Stored inside
/// `settings.json` under `shortcuts`, keyed by action id, so future shortcut
/// actions need no migration. Decoding is tolerant: missing keys take the
/// conservative defaults and unknown modifier strings are dropped.
public struct ClipboardShortcutSetting: Codable, Equatable, Sendable {
    /// Modifier names persisted in settings. `fn` is intentionally absent:
    /// Carbon `RegisterEventHotKey` cannot register fn-based combos, so the
    /// recorder never offers it and decode drops it.
    public static let knownModifiers: Set<String> = ["command", "shift", "option", "control"]

    /// Action id for the quick picker shortcut inside
    /// `ClipboardSettings.shortcuts`.
    public static let quickPickerActionID = "quickPicker"

    /// Default quick picker shortcut: ⌥⌘V, disabled until the user enables
    /// it in Settings (contract 8: new capabilities default off).
    public static let quickPickerDefault = ClipboardShortcutSetting(
        enabled: false,
        keyCode: 9,
        modifiers: ["option", "command"]
    )

    public var enabled: Bool
    /// macOS virtual key code (kVK_* values; 9 = V).
    public var keyCode: Int
    /// Sorted list drawn from `knownModifiers`.
    public var modifiers: [String]

    public init(enabled: Bool, keyCode: Int, modifiers: [String]) {
        self.enabled = enabled
        self.keyCode = keyCode
        self.modifiers = Self.normalize(modifiers)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case keyCode
        case modifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        keyCode = try container.decodeIfPresent(Int.self, forKey: .keyCode)
            ?? Self.quickPickerDefault.keyCode
        let decodedModifiers = try container.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        modifiers = Self.normalize(decodedModifiers)
    }

    /// Carbon modifier mask for `RegisterEventHotKey`:
    /// command = 0x0100, shift = 0x0200, option = 0x0800, control = 0x1000.
    public var carbonModifierFlags: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains("command") {
            flags |= 0x0100
        }
        if modifiers.contains("shift") {
            flags |= 0x0200
        }
        if modifiers.contains("option") {
            flags |= 0x0800
        }
        if modifiers.contains("control") {
            flags |= 0x1000
        }
        return flags
    }

    /// A registrable combo needs at least one of ⌘/⌥/⌃. Shift-only (or
    /// bare-key) shortcuts are rejected: they would shadow ordinary typing.
    public var isValid: Bool {
        guard keyCode >= 0, keyCode <= 0xFFFF else {
            return false
        }
        return !Set(modifiers).intersection(["command", "option", "control"]).isEmpty
    }

    /// Human-readable rendering, e.g. "⌥⌘V". Modifier order follows the
    /// macOS convention ⌃⌥⇧⌘. Unknown key codes render as "Key <n>".
    public var displayString: String {
        var parts = ""
        if modifiers.contains("control") {
            parts += "⌃"
        }
        if modifiers.contains("option") {
            parts += "⌥"
        }
        if modifiers.contains("shift") {
            parts += "⇧"
        }
        if modifiers.contains("command") {
            parts += "⌘"
        }
        return parts + Self.keyName(for: keyCode)
    }

    /// Drops unknown modifier names and duplicates, and keeps a stable order.
    private static func normalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.filter { knownModifiers.contains($0) && seen.insert($0).inserted }
    }

    /// kVK virtual key code → display name (US ANSI layout). Unknown codes
    /// fall back to "Key <n>" so any recorded key still renders.
    public static func keyName(for keyCode: Int) -> String {
        if let name = keyNames[keyCode] {
            return name
        }
        return "Key \(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear",
        75: "Keypad /", 76: "Keypad Enter", 78: "Keypad -", 81: "Keypad =",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3",
        86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7",
        91: "Keypad 8", 92: "Keypad 9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12",
        113: "F15", 114: "Help", 115: "Home", 116: "Page Up",
        117: "Forward Delete", 118: "F4", 119: "End", 120: "F2",
        121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
