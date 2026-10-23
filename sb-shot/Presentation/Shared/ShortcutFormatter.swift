import AppKit
import SwiftUI

enum ShortcutFormatter {
    private static let keyCodeNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 50: "`",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        49: "Espacio", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func display(_ shortcut: GlobalShortcut) -> String {
        let flags = shortcut.modifiers
        var output = ""
        if flags.contains(.control) {
            output += "⌃"
        }
        if flags.contains(.option) {
            output += "⌥"
        }
        if flags.contains(.shift) {
            output += "⇧"
        }
        if flags.contains(.command) {
            output += "⌘"
        }
        return output + keyName(for: shortcut.keyCode)
    }

    static func keyName(for keyCode: UInt32) -> String {
        keyCodeNames[keyCode] ?? "Tecla \(keyCode)"
    }

    /// Equivalente para mostrar el atajo en los menus de SwiftUI.
    static func keyboardShortcut(for shortcut: GlobalShortcut?) -> KeyboardShortcut? {
        guard
            let shortcut,
            let name = keyCodeNames[shortcut.keyCode],
            name.count == 1,
            let character = name.lowercased().first
        else { return nil }

        var modifiers: EventModifiers = []
        if shortcut.modifiers.contains(.command) {
            modifiers.insert(.command)
        }
        if shortcut.modifiers.contains(.shift) {
            modifiers.insert(.shift)
        }
        if shortcut.modifiers.contains(.option) {
            modifiers.insert(.option)
        }
        if shortcut.modifiers.contains(.control) {
            modifiers.insert(.control)
        }

        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}

extension View {
    @ViewBuilder
    func globalShortcut(_ shortcut: GlobalShortcut?) -> some View {
        if let keyboardShortcut = ShortcutFormatter.keyboardShortcut(for: shortcut) {
            self.keyboardShortcut(keyboardShortcut)
        } else {
            self
        }
    }
}
