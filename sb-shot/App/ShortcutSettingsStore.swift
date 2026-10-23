import AppKit
import Combine

struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiersRawValue: UInt

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }

    static let `default` = GlobalShortcut(
        keyCode: 19,
        modifiersRawValue: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )
}

@MainActor
final class ShortcutSettingsStore: ObservableObject {
    @Published var isRecordingShortcut = false

    @Published var shortcut: GlobalShortcut? {
        didSet {
            persist()
        }
    }

    private let defaults: UserDefaults
    private let key = "sbshot.globalShortcut"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode(GlobalShortcut?.self, from: data)
        {
            shortcut = value
        } else {
            shortcut = .default
        }
    }

    func resetToDefault() {
        shortcut = .default
    }

    private func persist() {
        let encoded = try? JSONEncoder().encode(shortcut)
        defaults.set(encoded, forKey: key)
    }
}
