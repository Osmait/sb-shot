import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: ShortcutSettingsStore

    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Atajo global")
                .font(.title3.weight(.semibold))

            Text("Define el atajo para iniciar la captura de region desde cualquier app.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    toggleRecorder()
                } label: {
                    Label(
                        isRecording ? "Presiona una combinacion" : shortcutLabel,
                        systemImage: isRecording ? "keyboard.badge.ellipsis" : "keyboard"
                    )
                    .frame(minWidth: 240, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)

                Button("Desactivar") {
                    stopRecording()
                    settingsStore.shortcut = nil
                }

                Button("Restaurar") {
                    stopRecording()
                    settingsStore.resetToDefault()
                }
            }

            Text("Default recomendado: \(display(for: .default))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 220)
        .onDisappear {
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            stopRecording()
        }
    }

    private var shortcutLabel: String {
        guard let shortcut = settingsStore.shortcut else {
            return "Sin atajo"
        }
        return display(for: shortcut)
    }

    private func toggleRecorder() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        settingsStore.isRecordingShortcut = true

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleCapture(event: event)
        }
    }

    private func stopRecording() {
        isRecording = false
        settingsStore.isRecordingShortcut = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleCapture(event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        if event.keyCode == 53 {
            stopRecording()
            return nil
        }

        let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]
        let modifiers = event.modifierFlags.intersection(allowedModifiers)

        guard !modifiers.isEmpty else {
            NSSound.beep()
            return nil
        }

        settingsStore.shortcut = GlobalShortcut(
            keyCode: UInt32(event.keyCode),
            modifiersRawValue: modifiers.rawValue
        )
        stopRecording()
        return nil
    }

    private func display(for shortcut: GlobalShortcut) -> String {
        let flags = shortcut.modifiers

        var output = ""
        if flags.contains(.control) { output += "^" }
        if flags.contains(.option) { output += "⌥" }
        if flags.contains(.shift) { output += "⇧" }
        if flags.contains(.command) { output += "⌘" }

        output += keyString(for: shortcut.keyCode)
        return output
    }

    private static let keyCodeNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M",
    ]

    private func keyString(for keyCode: UInt32) -> String {
        Self.keyCodeNames[keyCode] ?? "Key \(keyCode)"
    }
}
