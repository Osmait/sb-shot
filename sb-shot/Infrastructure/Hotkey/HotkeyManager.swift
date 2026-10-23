import AppKit
import Carbon

final class HotkeyManager {
    var onHotKeyPressed: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var currentHotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: 1)

    init() {
        installHandler()
    }

    deinit {
        unregisterCurrentHotKey()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(shortcut: GlobalShortcut?) {
        unregisterCurrentHotKey()

        guard let shortcut else { return }

        let modifiers = carbonModifiers(from: shortcut.modifiers)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            shortcut.keyCode,
            modifiers,
            currentHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else { return }
        self.hotKeyRef = hotKeyRef
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event: event)
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )
    }

    private func handle(event: EventRef) -> OSStatus {
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

        guard status == noErr else { return status }
        guard hotKeyID.signature == Self.signature else { return noErr }

        onHotKeyPressed?()
        return noErr
    }

    private func unregisterCurrentHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0

        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        return modifiers
    }

    private static let signature: OSType = 0x5342_4854
}
