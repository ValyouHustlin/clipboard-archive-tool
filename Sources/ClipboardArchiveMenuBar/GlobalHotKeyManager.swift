import AppKit
import Carbon.HIToolbox
import Foundation

/// Registers system-wide keyboard shortcuts via Carbon
/// `RegisterEventHotKey` (expansion contract 8: no Accessibility permission,
/// no CGEvent tap). Owned for the app's lifetime by `ClipboardMenuBarApp`,
/// which makes `Unmanaged.passUnretained(self)` as handler user data safe.
///
/// App-target Carbon events are delivered on the main thread, so the handler
/// re-enters the main actor with `MainActor.assumeIsolated`.
@MainActor
final class GlobalHotKeyManager {
    enum RegistrationResult: Equatable {
        case registered
        /// Another app already owns the combo (`eventHotKeyExistsErr`,
        /// OSStatus -9878). The shortcut stays saved but is not active;
        /// callers must surface this, never swallow it.
        case conflict(OSStatus)
        case failed(OSStatus)
    }

    /// FourCC 'CLAR' identifying this app's hot keys.
    private static let signature: OSType = 0x434C_4152

    var onHotKey: ((UInt32) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    func register(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32) -> RegistrationResult {
        unregister(id: id)
        installEventHandlerIfNeeded()

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else {
            if status == OSStatus(eventHotKeyExistsErr) {
                return .conflict(status)
            }
            return .failed(status)
        }
        hotKeyRefs[id] = hotKeyRef
        return .registered
    }

    func unregister(id: UInt32) {
        guard let hotKeyRef = hotKeyRefs.removeValue(forKey: id) else {
            return
        }
        UnregisterEventHotKey(hotKeyRef)
    }

    func unregisterAll() {
        for id in Array(hotKeyRefs.keys) {
            unregister(id: id)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return noErr
            }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == GlobalHotKeyManager.signature else {
                return status
            }
            // App-target Carbon events arrive on the main thread.
            MainActor.assumeIsolated {
                let manager = Unmanaged<GlobalHotKeyManager>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                manager.onHotKey?(hotKeyID.id)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }
}
