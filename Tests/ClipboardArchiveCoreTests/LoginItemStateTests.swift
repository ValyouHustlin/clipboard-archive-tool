import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 9: launch-at-login state mapping. These tests pin the pure model
/// behind the Settings toggle — the raw-value mapping mirrors
/// `SMAppService.Status` (0 notRegistered, 1 enabled, 2 requiresApproval,
/// 3 notFound) so the UI wrapper contains no decisions of its own. No test
/// here registers anything; registration is user-click-only by contract.
@Suite("Login Item State")
struct LoginItemStateTests {
    @Test
    func testRawValueMappingMatchesSMAppServiceStatus() {
        #expect(ClipboardLoginItemState(smAppServiceStatusRawValue: 0) == .notRegistered)
        #expect(ClipboardLoginItemState(smAppServiceStatusRawValue: 1) == .enabled)
        #expect(ClipboardLoginItemState(smAppServiceStatusRawValue: 2) == .requiresApproval)
        #expect(ClipboardLoginItemState(smAppServiceStatusRawValue: 3) == .notFound)
    }

    @Test
    func testUnknownRawValuesArePreservedNotCoerced() {
        let future = ClipboardLoginItemState(smAppServiceStatusRawValue: 7)
        #expect(future == .unknown(7))
        // Unknown status must fail safe: toggle reads off, no approval
        // shortcut, but the control stays usable so the user is not locked
        // out by a future macOS value.
        #expect(!future.reflectsToggleOn)
        #expect(!future.showsOpenLoginItemsButton)
        #expect(future.allowsToggle)
        #expect(future.statusDescription.contains("7"))
    }

    @Test
    func testToggleReflectsUserIntentIncludingPendingApproval() {
        // Enabled and requires-approval both render checked: the user asked
        // for login launch; approval is macOS-side, and unchecking is how
        // the request gets withdrawn.
        #expect(ClipboardLoginItemState.enabled.reflectsToggleOn)
        #expect(ClipboardLoginItemState.requiresApproval.reflectsToggleOn)
        #expect(!ClipboardLoginItemState.notRegistered.reflectsToggleOn)
        #expect(!ClipboardLoginItemState.notFound.reflectsToggleOn)
    }

    @Test
    func testApprovalShortcutOnlyForRequiresApproval() {
        #expect(ClipboardLoginItemState.requiresApproval.showsOpenLoginItemsButton)
        #expect(!ClipboardLoginItemState.enabled.showsOpenLoginItemsButton)
        #expect(!ClipboardLoginItemState.notRegistered.showsOpenLoginItemsButton)
        #expect(!ClipboardLoginItemState.notFound.showsOpenLoginItemsButton)
    }

    @Test
    func testNotFoundDisablesToggleAndExplainsAppLocation() {
        // A bare development binary (no .app bundle) reads notFound; the
        // toggle must disable and the copy must explain the app-location
        // requirement instead of pretending the feature works.
        let state = ClipboardLoginItemState.notFound
        #expect(!state.allowsToggle)
        #expect(state.statusDescription.lowercased().contains("location"))
    }

    @Test
    func testEveryStateHasNonEmptyPlainLanguageStatus() {
        let states: [ClipboardLoginItemState] = [
            .notRegistered, .enabled, .requiresApproval, .notFound, .unknown(42)
        ]
        for state in states {
            #expect(!state.statusDescription.isEmpty)
        }
        // The approval copy must point at the exact System Settings pane.
        #expect(
            ClipboardLoginItemState.requiresApproval.statusDescription
                .contains("Login Items")
        )
    }
}
