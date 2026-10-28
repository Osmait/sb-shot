import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var recording: RecordingViewModel

    var body: some View {
        switch recording.state {
        case .recording:
            Text("\(Image(systemName: "stop.circle.fill")) \(recording.elapsedText)")
                .monospacedDigit()
        case .processing:
            Image(systemName: "hourglass")
        case .idle, .preparing:
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

struct MenuBarView: View {
    let container: AppContainer
    @ObservedObject var recording: RecordingViewModel
    @ObservedObject var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if recording.isRecording {
            Button("Stop Recording (\(recording.elapsedText))", systemImage: "stop.circle.fill") {
                recording.stop()
            }
            .globalShortcut(settings.shortcut(for: .recordArea))

            Button("Restart Recording", systemImage: "arrow.counterclockwise") {
                recording.restart()
            }

            Button("Discard Recording", systemImage: "trash") {
                recording.cancel()
            }

            Divider()
        }

        Section("Capture") {
            actionButton(.captureArea)
            actionButton(.capturePreviousArea)
                .disabled(settings.lastCaptureArea == nil)
            actionButton(.captureFullscreen)
            actionButton(.captureWindow)

            Menu("Timed Capture") {
                ForEach([3, 5, 10], id: \.self) { seconds in
                    Button("\(seconds) seconds") {
                        container.captureViewModel.capture(.timed(seconds: seconds))
                    }
                }
            }

            actionButton(.captureText)
        }

        Section("Record") {
            actionButton(.recordArea)
                .disabled(recording.isBusy)
            actionButton(.recordFullscreen)
                .disabled(recording.isBusy)

            Picker("Format", selection: $settings.recordingFormat) {
                ForEach(RecordingFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }

            Toggle("Record Microphone", isOn: $settings.recordingMicrophone)
            Toggle("Record System Audio", isOn: $settings.recordingSystemAudio)
        }

        Divider()

        Button("Annotate Image…", systemImage: "pencil.and.scribble") {
            container.captureViewModel.annotateImageFile()
        }

        actionButton(.openHistory)

        Button("Open Screenshots Folder", systemImage: "folder") {
            container.fileStorage.openSaveFolder()
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit sb-shot") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func actionButton(_ action: CaptureAction) -> some View {
        Button(action.title, systemImage: action.iconName) {
            container.perform(action)
        }
        .globalShortcut(settings.shortcut(for: action))
    }
}
