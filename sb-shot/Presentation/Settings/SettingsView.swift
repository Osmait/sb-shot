import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let fileStorage: FileStorage
    @ObservedObject var history: HistoryStore

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, fileStorage: fileStorage, history: history)
                .tabItem { Label("General", systemImage: "gearshape") }

            CaptureSettingsTab(settings: settings)
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }

            RecordingSettingsTab(settings: settings)
                .tabItem { Label("Recording", systemImage: "record.circle") }

            QuickAccessSettingsTab(settings: settings)
                .tabItem { Label("Quick Access", systemImage: "rectangle.stack") }

            ShortcutsSettingsTab(settings: settings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 600, height: 470)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    let fileStorage: FileStorage
    @ObservedObject var history: HistoryStore

    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var launchNeedsApproval = LaunchAtLogin.requiresApproval
    @State private var folderPath = ""
    @State private var hasCustomFolder = false

    var body: some View {
        Form {
            Section {
                // Custom binding instead of onChange: reflecting the real state doesn't call setEnabled again.
                Toggle("Open sb-shot at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        LaunchAtLogin.setEnabled(value)
                        refreshLaunchAtLogin()
                    }
                ))
                if launchNeedsApproval {
                    LabeledContent {
                        Button("Open System Settings") { LaunchAtLogin.openSystemSettings() }
                    } label: {
                        Text("Needs approval in System Settings › General › Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Play sound on capture", isOn: $settings.playSound)
            }

            Section("After Capture") {
                Toggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                Toggle("Show Quick Access", isOn: $settings.showQuickAccess)
                Toggle("Open the editor directly", isOn: $settings.openEditorAfterCapture)
                Toggle("Save automatically to the folder", isOn: $settings.autoSave)
            }

            Section("Files") {
                LabeledContent("Save folder") {
                    HStack {
                        Text(folderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") {
                            fileStorage.chooseSaveFolder()
                            refreshFolder()
                        }
                        if hasCustomFolder {
                            Button("Reset") {
                                fileStorage.resetSaveFolder()
                                refreshFolder()
                            }
                        }
                    }
                }

                Picker("Image format", selection: $settings.imageFormat) {
                    ForEach(ImageFileFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                TextField("File name prefix", text: $settings.fileNamePrefix)
                Text("Example: \(fileStorage.fileName(prefix: settings.fileNamePrefix, fileExtension: settings.imageFormat.fileExtension))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("History") {
                Toggle("Keep capture history", isOn: $settings.keepHistory)
                LabeledContent("Saved items: \(history.entries.count)") {
                    Button("Clear History", role: .destructive) { history.clear() }
                        .disabled(history.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshFolder()
            refreshLaunchAtLogin()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLogin()
        }
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isOn
        launchNeedsApproval = LaunchAtLogin.requiresApproval
    }

    private func refreshFolder() {
        folderPath = fileStorage.saveFolderDisplayPath
        hasCustomFolder = fileStorage.hasCustomSaveFolder
    }
}

// MARK: - Capture

private struct CaptureSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Selection") {
                Toggle("Show magnifier with pixels and color", isOn: $settings.showMagnifier)
                Toggle("Show crosshair", isOn: $settings.showCrosshair)
                Toggle("Freeze the screen while selecting", isOn: $settings.freezeScreen)
                Text("When frozen, the screenshot is exactly what you see when the selection starts (useful for menus and animations).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Toggle("Include shadow in window captures", isOn: $settings.windowShadow)
                Toggle("Hide desktop icons", isOn: $settings.hideDesktopIcons)
                Toggle("Save at 1x size on Retina displays", isOn: $settings.downscaleRetina)
            }

            Section("Shortcuts While Selecting") {
                hint("Drag", "Select an area")
                hint("Click", "Choose the window under the cursor")
                hint("Click on the desktop", "Choose the full screen")
                hint("Hold Space", "Move the selection while dragging")
                hint("Shift", "Square selection")
                hint("Enter", "Capture the full screen")
                hint("Esc or right-click", "Cancel")
            }
        }
        .formStyle(.grouped)
    }

    private func hint(_ key: LocalizedStringKey, _ description: LocalizedStringKey) -> some View {
        LabeledContent(description) {
            Text(key)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Recording

private struct RecordingSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Video") {
                Picker("Format", selection: $settings.recordingFormat) {
                    ForEach(RecordingFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Picker("Frames per second", selection: $settings.recordingFPS) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Retina quality", isOn: $settings.recordingRetina)
                Picker("Countdown", selection: $settings.recordingCountdown) {
                    Text("No countdown").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
            }

            Section("Cursor and Audio") {
                Toggle("Show the cursor", isOn: $settings.recordingShowsCursor)
                Toggle("Highlight clicks", isOn: $settings.recordingHighlightsClicks)
                Toggle("Record system audio", isOn: $settings.recordingSystemAudio)
                Toggle("Record microphone", isOn: $settings.recordingMicrophone)
            }

            Section("GIF") {
                Picker("Frames per second", selection: $settings.gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                    Text("25 fps").tag(25)
                }
                Picker("Maximum width", selection: $settings.gifMaxWidth) {
                    Text("640 px").tag(640.0)
                    Text("960 px").tag(960.0)
                    Text("1280 px").tag(1280.0)
                    Text("1920 px").tag(1920.0)
                }
            }

            Section {
                Text("The same shortcut starts and stops the recording. You can also stop it from the control bar or the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Quick Access

private struct QuickAccessSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Position", selection: $settings.quickAccessPosition) {
                    ForEach(QuickAccessPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                Picker("Close automatically", selection: $settings.quickAccessAutoClose) {
                    Text("Never").tag(0)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                    Text("After 1 minute").tag(60)
                }
                Toggle("Close after dragging to another app", isOn: $settings.quickAccessClosesAfterDrag)
            }

            Section("How to Use") {
                Text("Hover over the thumbnail to copy, save, annotate or pin it. Drag it into any app to drop the file, click to open the editor, or swipe with two fingers to dismiss it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(settings: settings, action: action)
                    } label: {
                        Label(action.title, systemImage: action.iconName)
                        if settings.unavailableShortcuts.contains(action) {
                            Text("Shortcut in use by another app")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } footer: {
                HStack {
                    Text("Click a shortcut and press the new key combination. Esc cancels.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        settings.resetShortcuts()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRecorder: View {
    @ObservedObject var settings: AppSettings
    let action: CaptureAction

    @State private var monitor: Any?

    private var isRecording: Bool {
        settings.recordingShortcutFor == action
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(label)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            Button {
                stopRecording()
                settings.setShortcut(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove shortcut")
            .opacity(settings.shortcut(for: action) == nil ? 0 : 1)
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording {
            return String(localized: "Press keys…")
        }
        guard let shortcut = settings.shortcut(for: action) else { return String(localized: "No shortcut") }
        return ShortcutFormatter.display(shortcut)
    }

    private func startRecording() {
        stopRecording()
        settings.recordingShortcutFor = action

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard settings.recordingShortcutFor == action else { return event }

            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !modifiers.isEmpty else {
                NSSound.beep()
                return nil
            }

            settings.setShortcut(GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers), for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if settings.recordingShortcutFor == action {
            settings.recordingShortcutFor = nil
        }
    }
}
