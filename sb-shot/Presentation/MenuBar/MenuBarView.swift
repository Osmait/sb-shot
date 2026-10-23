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
            Image(systemName: "camera.viewfinder")
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
            Button("Detener grabación (\(recording.elapsedText))", systemImage: "stop.circle.fill") {
                recording.stop()
            }
            .globalShortcut(settings.shortcut(for: .recordArea))

            Button("Reiniciar grabación", systemImage: "arrow.counterclockwise") {
                recording.restart()
            }

            Button("Descartar grabación", systemImage: "trash") {
                recording.cancel()
            }

            Divider()
        }

        Section("Capturar") {
            actionButton(.captureArea)
            actionButton(.capturePreviousArea)
                .disabled(settings.lastCaptureArea == nil)
            actionButton(.captureFullscreen)
            actionButton(.captureWindow)

            Menu("Captura con temporizador") {
                ForEach([3, 5, 10], id: \.self) { seconds in
                    Button("\(seconds) segundos") {
                        container.captureViewModel.capture(.timed(seconds: seconds))
                    }
                }
            }

            actionButton(.captureText)
        }

        Section("Grabar") {
            actionButton(.recordArea)
                .disabled(recording.isBusy)
            actionButton(.recordFullscreen)
                .disabled(recording.isBusy)

            Picker("Formato", selection: $settings.recordingFormat) {
                ForEach(RecordingFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }

            Toggle("Grabar micrófono", isOn: $settings.recordingMicrophone)
            Toggle("Grabar audio del sistema", isOn: $settings.recordingSystemAudio)
        }

        Divider()

        Button("Anotar imagen…", systemImage: "pencil.and.scribble") {
            container.captureViewModel.annotateImageFile()
        }

        actionButton(.openHistory)

        Button("Abrir carpeta de capturas", systemImage: "folder") {
            container.fileStorage.openSaveFolder()
        }

        Divider()

        Button("Ajustes…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Salir de sb-shot") {
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
