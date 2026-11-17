import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Shortcut Setting")
struct ShortcutSettingTests {
    private func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    @Test
    func testQuickPickerDefaultIsDisabledOptionCommandV() {
        let setting = ClipboardShortcutSetting.quickPickerDefault
        #expect(setting.enabled == false)
        #expect(setting.keyCode == 9)
        #expect(setting.modifiers == ["option", "command"])
        #expect(setting.displayString == "⌥⌘V")
        #expect(setting.isValid)
    }

    @Test
    func testCarbonModifierFlagsExactValues() {
        // Carbon masks: command=0x0100, shift=0x0200, option=0x0800, control=0x1000.
        let optionCommand = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 9,
            modifiers: ["option", "command"]
        )
        #expect(optionCommand.carbonModifierFlags == 2304) // 0x0900

        let controlShift = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 9,
            modifiers: ["control", "shift"]
        )
        #expect(controlShift.carbonModifierFlags == 0x1200)

        let commandOnly = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 0,
            modifiers: ["command"]
        )
        #expect(commandOnly.carbonModifierFlags == 0x0100)

        let shiftOnly = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 0,
            modifiers: ["shift"]
        )
        #expect(shiftOnly.carbonModifierFlags == 0x0200)

        let optionOnly = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 0,
            modifiers: ["option"]
        )
        #expect(optionOnly.carbonModifierFlags == 0x0800)

        let controlOnly = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 0,
            modifiers: ["control"]
        )
        #expect(controlOnly.carbonModifierFlags == 0x1000)

        let all = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 0,
            modifiers: ["command", "shift", "option", "control"]
        )
        #expect(all.carbonModifierFlags == 0x1B00)

        let none = ClipboardShortcutSetting(enabled: true, keyCode: 0, modifiers: [])
        #expect(none.carbonModifierFlags == 0)
    }

    @Test
    func testIsValidRequiresCommandOptionOrControl() {
        #expect(ClipboardShortcutSetting(enabled: true, keyCode: 9, modifiers: ["command"]).isValid)
        #expect(ClipboardShortcutSetting(enabled: true, keyCode: 9, modifiers: ["option"]).isValid)
        #expect(ClipboardShortcutSetting(enabled: true, keyCode: 9, modifiers: ["control"]).isValid)
        #expect(ClipboardShortcutSetting(
            enabled: true,
            keyCode: 9,
            modifiers: ["shift", "command"]
        ).isValid)

        // Shift-only and bare-key combos would shadow ordinary typing.
        #expect(!ClipboardShortcutSetting(enabled: true, keyCode: 9, modifiers: ["shift"]).isValid)
        #expect(!ClipboardShortcutSetting(enabled: true, keyCode: 9, modifiers: []).isValid)
        // Nonsensical key codes are rejected.
        #expect(!ClipboardShortcutSetting(enabled: true, keyCode: -1, modifiers: ["command"]).isValid)
    }

    @Test
    func testDisplayStringUsesMacModifierOrderAndKeyTable() {
        #expect(ClipboardShortcutSetting(
            enabled: true,
            keyCode: 9,
            modifiers: ["command", "shift", "option", "control"]
        ).displayString == "⌃⌥⇧⌘V")
        #expect(ClipboardShortcutSetting(
            enabled: true,
            keyCode: 49,
            modifiers: ["command"]
        ).displayString == "⌘Space")
        #expect(ClipboardShortcutSetting(
            enabled: true,
            keyCode: 36,
            modifiers: ["control"]
        ).displayString == "⌃Return")
        #expect(ClipboardShortcutSetting(
            enabled: true,
            keyCode: 126,
            modifiers: ["option"]
        ).displayString == "⌥↑")
        #expect(ClipboardShortcutSetting(
            enabled: true,
            keyCode: 122,
            modifiers: ["command"]
        ).displayString == "⌘F1")
    }

    @Test
    func testDisplayStringFallsBackForUnknownKeyCode() {
        let setting = ClipboardShortcutSetting(enabled: true, keyCode: 200, modifiers: ["command"])
        #expect(setting.displayString == "⌘Key 200")
    }

    @Test
    func testUnknownModifierStringsAreDroppedOnDecode() throws {
        let json = #"{"enabled":true,"keyCode":9,"modifiers":["option","hyper","command","fn"]}"#
        let setting = try decoder().decode(ClipboardShortcutSetting.self, from: Data(json.utf8))
        #expect(setting.enabled)
        #expect(setting.keyCode == 9)
        #expect(setting.modifiers == ["option", "command"])
    }

    @Test
    func testMissingKeysDecodeToConservativeDefaults() throws {
        let setting = try decoder().decode(
            ClipboardShortcutSetting.self,
            from: Data("{}".utf8)
        )
        #expect(setting.enabled == false)
        #expect(setting.keyCode == ClipboardShortcutSetting.quickPickerDefault.keyCode)
        #expect(setting.modifiers.isEmpty)
        #expect(!setting.isValid)
    }

    @Test
    func testDuplicateModifiersAreDeduplicated() {
        let setting = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 9,
            modifiers: ["command", "command", "option"]
        )
        #expect(setting.modifiers == ["command", "option"])
    }
}
