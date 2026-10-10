import Carbon.HIToolbox
import Foundation

/// ⌥⌘K from any app: start talking, send, or interrupt. Carbon hot keys need no
/// Accessibility permission, unlike a global key-event monitor.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()
    static let displayName = "⌥⌘K"

    var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in GlobalHotKey.shared.action?() }
                return noErr
            }, 1, &eventType, nil, &handlerRef)
        }
        let identifier = EventHotKeyID(signature: OSType(0x5850_4E4B), id: 1) // "XPNK"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(optionKey | cmdKey), identifier,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
