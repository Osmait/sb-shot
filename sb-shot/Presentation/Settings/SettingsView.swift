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
                .tabItem { Label("Captura", systemImage: "camera.viewfinder") }

            RecordingSettingsTab(settings: settings)
                .tabItem { Label("Grabación", systemImage: "record.circle") }

            QuickAccessSettingsTab(settings: settings)
                .tabItem { Label("Acceso rápido", systemImage: "rectangle.stack") }

            ShortcutsSettingsTab(settings: settings)
                .tabItem { Label("Atajos", systemImage: "keyboard") }
        }
        .frame(width: 600, height: 470)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    let fileStorage: FileStorage
    @ObservedObject var history: HistoryStore

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var folderPath = ""
    @State private var hasCustomFolder = false

    var body: some View {
        Form {
            Section {
                Toggle("Abrir sb-shot al iniciar sesión", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        LaunchAtLogin.setEnabled(value)
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                Toggle("Reproducir sonido al capturar", isOn: $settings.playSound)
            }

            Section("Después de capturar") {
                Toggle("Copiar al portapapeles", isOn: $settings.copyToClipboard)
                Toggle("Mostrar acceso rápido", isOn: $settings.showQuickAccess)
                Toggle("Abrir el editor directamente", isOn: $settings.openEditorAfterCapture)
                Toggle("Guardar automáticamente en la carpeta", isOn: $settings.autoSave)
            }

            Section("Archivos") {
                LabeledContent("Carpeta de guardado") {
                    HStack {
                        Text(folderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Cambiar…") {
                            fileStorage.chooseSaveFolder()
                            refreshFolder()
                        }
                        if hasCustomFolder {
                            Button("Restablecer") {
                                fileStorage.resetSaveFolder()
                                refreshFolder()
                            }
                        }
                    }
                }

                Picker("Formato de imagen", selection: $settings.imageFormat) {
                    ForEach(ImageFileFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }

                TextField("Prefijo del nombre", text: $settings.fileNamePrefix)
                Text("Ejemplo: \(fileStorage.fileName(prefix: settings.fileNamePrefix, fileExtension: settings.imageFormat.fileExtension))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Historial") {
                Toggle("Guardar historial de capturas", isOn: $settings.keepHistory)
                LabeledContent("\(history.entries.count) elementos guardados") {
                    Button("Borrar historial", role: .destructive) { history.clear() }
                        .disabled(history.entries.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshFolder)
    }

    private func refreshFolder() {
        folderPath = fileStorage.saveFolderDisplayPath
        hasCustomFolder = fileStorage.hasCustomSaveFolder
    }
}

// MARK: - Captura

private struct CaptureSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Selección") {
                Toggle("Mostrar lupa con píxeles y color", isOn: $settings.showMagnifier)
                Toggle("Mostrar retícula", isOn: $settings.showCrosshair)
                Toggle("Congelar la pantalla al seleccionar", isOn: $settings.freezeScreen)
                Text("Al congelar, la captura es exactamente lo que ves en el momento de iniciar la selección (útil para menús y animaciones).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Resultado") {
                Toggle("Incluir sombra en capturas de ventana", isOn: $settings.windowShadow)
                Toggle("Ocultar iconos del escritorio", isOn: $settings.hideDesktopIcons)
                Toggle("Guardar a tamaño 1x en pantallas Retina", isOn: $settings.downscaleRetina)
            }

            Section("Atajos dentro de la selección") {
                hint("Arrastrar", "Seleccionar un área")
                hint("Clic", "Elegir la ventana bajo el cursor")
                hint("Clic en el escritorio", "Elegir la pantalla completa")
                hint("Mantener Espacio", "Mover la selección mientras arrastras")
                hint("Shift", "Selección cuadrada")
                hint("Enter", "Capturar la pantalla completa")
                hint("Esc o clic derecho", "Cancelar")
            }
        }
        .formStyle(.grouped)
    }

    private func hint(_ key: String, _ description: String) -> some View {
        LabeledContent(description) {
            Text(key)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Grabacion

private struct RecordingSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Video") {
                Picker("Formato", selection: $settings.recordingFormat) {
                    ForEach(RecordingFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Picker("Cuadros por segundo", selection: $settings.recordingFPS) {
                    Text("24 fps").tag(24)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Calidad Retina", isOn: $settings.recordingRetina)
                Picker("Cuenta regresiva", selection: $settings.recordingCountdown) {
                    Text("Sin cuenta regresiva").tag(0)
                    Text("3 segundos").tag(3)
                    Text("5 segundos").tag(5)
                }
            }

            Section("Cursor y audio") {
                Toggle("Mostrar el cursor", isOn: $settings.recordingShowsCursor)
                Toggle("Resaltar los clics", isOn: $settings.recordingHighlightsClicks)
                Toggle("Grabar audio del sistema", isOn: $settings.recordingSystemAudio)
                Toggle("Grabar micrófono", isOn: $settings.recordingMicrophone)
            }

            Section("GIF") {
                Picker("Cuadros por segundo", selection: $settings.gifFPS) {
                    Text("10 fps").tag(10)
                    Text("15 fps").tag(15)
                    Text("20 fps").tag(20)
                    Text("25 fps").tag(25)
                }
                Picker("Ancho máximo", selection: $settings.gifMaxWidth) {
                    Text("640 px").tag(640.0)
                    Text("960 px").tag(960.0)
                    Text("1280 px").tag(1280.0)
                    Text("1920 px").tag(1920.0)
                }
            }

            Section {
                Text("El mismo atajo inicia y detiene la grabación. También puedes detenerla desde la barra de control o el menú.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Acceso rapido

private struct QuickAccessSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Posición", selection: $settings.quickAccessPosition) {
                    ForEach(QuickAccessPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                Picker("Cerrar automáticamente", selection: $settings.quickAccessAutoClose) {
                    Text("Nunca").tag(0)
                    Text("Después de 5 segundos").tag(5)
                    Text("Después de 10 segundos").tag(10)
                    Text("Después de 30 segundos").tag(30)
                    Text("Después de 1 minuto").tag(60)
                }
                Toggle("Cerrar al arrastrar a otra app", isOn: $settings.quickAccessClosesAfterDrag)
            }

            Section("Cómo se usa") {
                Text("Pasa el cursor sobre la miniatura para copiar, guardar, anotar o fijar. Arrástrala a cualquier app para soltar el archivo, haz clic para abrir el editor o desliza con dos dedos para descartarla.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Atajos

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
                    }
                }
            } footer: {
                HStack {
                    Text("Haz clic en un atajo y presiona la nueva combinación. Esc cancela.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restaurar predeterminados") {
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
            .help("Quitar atajo")
            .opacity(settings.shortcut(for: action) == nil ? 0 : 1)
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording {
            return "Presiona teclas…"
        }
        guard let shortcut = settings.shortcut(for: action) else { return "Sin atajo" }
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
