import AppKit
import Carbon

/// Registra los atajos globales de cada accion con Carbon.
final class HotkeyManager {
    var onHotKeyPressed: ((CaptureAction) -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    /// Atajos pedidos en la ultima llamada a `register`, para no repetir el registro.
    private var requested: [CaptureAction: GlobalShortcut] = [:]
    /// Solo los atajos que el sistema acepto.
    private(set) var registered: [CaptureAction: GlobalShortcut] = [:]
    /// Acciones cuyo atajo no se pudo registrar (normalmente porque otra app ya lo usa).
    private(set) var failedActions: Set<CaptureAction> = []

    init() {
        installHandler()
    }

    deinit {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(_ shortcuts: [CaptureAction: GlobalShortcut]) {
        guard shortcuts != requested else { return }
        unregisterAll()
        requested = shortcuts

        for (action, shortcut) in shortcuts {
            guard let index = CaptureAction.allCases.firstIndex(of: action) else { continue }

            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                carbonModifiers(from: shortcut.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
                registered[action] = shortcut
            } else {
                failedActions.insert(action)
            }
        }
    }

    private func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        requested = [:]
        registered = [:]
        failedActions = []
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

        guard status == noErr, hotKeyID.signature == Self.signature else { return status }

        let index = Int(hotKeyID.id) - 1
        guard CaptureAction.allCases.indices.contains(index) else { return noErr }

        onHotKeyPressed?(CaptureAction.allCases[index])
        return noErr
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0

        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }

        return modifiers
    }

    private static let signature: OSType = 0x5342_4854
}
