import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Decide que hacer con cada captura o grabacion segun los ajustes, y ejecuta las acciones
/// del acceso rapido, el editor y el historial.
@MainActor
final class CaptureOutputHandler {
    private let settings: AppSettings
    private let clipboard: ImageFileClipboardWriting
    private let files: FileStorage
    private let history: HistoryStore
    private let quickAccess: QuickAccessPresenting
    private let editor: EditorPresenting
    private let videoEditor: VideoEditorPresenting
    private let pins: PinPresenting
    private let toast: ToastPresenting
    /// Las capturas se procesan en orden: cada una espera a la anterior antes de elegir nombre y portapapeles.
    private var screenshotPipeline: Task<Void, Never>?

    init(
        settings: AppSettings,
        clipboard: ImageFileClipboardWriting,
        files: FileStorage,
        history: HistoryStore,
        quickAccess: QuickAccessPresenting,
        editor: EditorPresenting,
        videoEditor: VideoEditorPresenting,
        pins: PinPresenting,
        toast: ToastPresenting
    ) {
        self.settings = settings
        self.clipboard = clipboard
        self.files = files
        self.history = history
        self.quickAccess = quickAccess
        self.editor = editor
        self.videoEditor = videoEditor
        self.pins = pins
        self.toast = toast
    }

    // MARK: - New captures

    func handleScreenshot(_ image: NSImage) {
        if settings.playSound {
            SoundPlayer.playCapture()
        }

        let previous = screenshotPipeline
        screenshotPipeline = Task { [weak self] in
            await previous?.value
            await self?.processScreenshot(image)
        }
    }

    /// Codifica la imagen una sola vez (fuera del hilo principal) y reutiliza los bytes para el archivo
    /// y el portapapeles.
    private func processScreenshot(_ image: NSImage) async {
        let format = settings.imageFormat
        let data = await files.encodeInBackground(image, as: format)
        let fileURL: URL? = if let data {
            try? await files.writeTemporary(data, fileExtension: format.fileExtension, prefix: settings.fileNamePrefix)
        } else {
            nil
        }

        if settings.copyToClipboard {
            if format == .png, let data {
                clipboard.copy(pngData: data, fileURL: fileURL)
            } else if let png = await files.encodeInBackground(image, as: .png) {
                clipboard.copy(pngData: png, fileURL: fileURL)
            }
        }

        // Sin archivo se pierde el acceso rapido, pero no el portapapeles ni el editor.
        guard let fileURL else {
            toast.show("No se pudo guardar la captura", systemImage: "exclamationmark.triangle")
            if settings.openEditorAfterCapture {
                openEditor(image)
            }
            return
        }

        let state = QuickAccessState(item: CaptureItem(content: .image(image), thumbnail: image, fileURL: fileURL))
        if settings.autoSave {
            state.savedURL = saveToFolder(fileURL, announce: false)
        }
        if settings.keepHistory {
            history.add(fileURL: fileURL, kind: .image)
        }

        if settings.openEditorAfterCapture {
            openEditor(image)
        } else if settings.showQuickAccess {
            showQuickAccess(state)
        } else {
            toast.show(settings.copyToClipboard ? "Captura copiada" : "Captura lista", systemImage: "checkmark.circle.fill")
        }
    }

    func handleRecording(_ rawURL: URL) async {
        let videoURL = files.temporaryURL(prefix: settings.fileNamePrefix, fileExtension: "mp4")
        let sourceURL = (try? FileManager.default.moveItem(at: rawURL, to: videoURL)) != nil ? videoURL : rawURL
        let thumbnail = await VideoExporter.thumbnail(for: sourceURL) ?? NSWorkspace.shared.icon(for: .mpeg4Movie)

        var item = CaptureItem(content: .video(sourceURL), thumbnail: thumbnail, fileURL: sourceURL)
        var gifFailed = false
        if settings.recordingFormat == .gif {
            toast.showProgress("Creando GIF…")
            if let gifURL = await makeGIF(from: sourceURL) {
                toast.hide()
                try? FileManager.default.removeItem(at: sourceURL)
                item = CaptureItem(content: .gif(gifURL), thumbnail: thumbnail, fileURL: gifURL)
            } else {
                // Se conserva la grabacion como video para no perderla.
                gifFailed = true
                toast.show("No se pudo crear el GIF; se conserva el video", systemImage: "exclamationmark.triangle")
            }
        }

        // El historial copia desde el temporal: la carpeta personalizada no es accesible sin su bookmark.
        let state = QuickAccessState(item: item)
        if settings.autoSave {
            state.savedURL = saveToFolder(item.fileURL, announce: false)
        }
        if settings.keepHistory {
            history.add(fileURL: item.fileURL, kind: item.videoURL != nil ? .video : .gif)
        }

        if settings.showQuickAccess {
            showQuickAccess(state)
        } else if !gifFailed {
            toast.show(settings.autoSave ? "Grabación guardada" : "Grabación lista", systemImage: "checkmark.circle.fill")
        }
    }

    func handleRecognizedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast.show("No se encontró texto", systemImage: "text.magnifyingglass")
            return
        }
        clipboard.copy(text: trimmed)
        let lines = trimmed.components(separatedBy: .newlines).count
        toast.show(lines == 1 ? "Texto copiado" : "Texto copiado (\(lines) líneas)", systemImage: "text.viewfinder")
    }

    // MARK: - Item actions

    func copy(_ item: CaptureItem) {
        if let image = item.image {
            // Reutiliza los bytes del archivo en lugar de volver a codificar la imagen.
            if !clipboard.copyImageFile(at: item.fileURL) {
                clipboard.copy(image: image)
            }
        } else {
            clipboard.copy(fileURL: item.fileURL)
        }
        toast.show("Copiado", systemImage: "doc.on.clipboard.fill")
    }

    func edit(_ item: CaptureItem) {
        switch item.content {
        case let .image(image):
            openEditor(image)
        case let .video(url):
            openVideoEditor(url)
        case let .gif(url):
            NSWorkspace.shared.open(url)
        }
    }

    func openEditor(_ image: NSImage) {
        editor.show(image: image, actions: EditorActions(
            onCopy: { [weak self] image in
                self?.clipboard.copy(image: image)
                self?.toast.show("Copiado", systemImage: "doc.on.clipboard.fill")
            },
            onSave: { [weak self] image in
                guard let self, let url = writeTemporary(image) else { return }
                saveToFolder(url, announce: true)
            },
            onSaveAs: { [weak self] image in
                guard let self, let url = writeTemporary(image) else { return }
                do {
                    if try files.saveWithPanel(url) != nil {
                        toast.show("Guardado", systemImage: "checkmark.circle.fill")
                    }
                } catch {
                    toast.show("No se pudo guardar el archivo", systemImage: "exclamationmark.triangle")
                }
            },
            onPin: { [weak self] image in
                self?.pin(image)
            }
        ))
    }

    func openVideoEditor(_ url: URL) {
        videoEditor.show(videoURL: url, actions: VideoEditorActions(
            onCopy: { [weak self] url in
                self?.clipboard.copy(fileURL: url)
                self?.toast.show("Copiado", systemImage: "doc.on.clipboard.fill")
            },
            onSave: { [weak self] url in
                guard let self, saveToFolder(url, announce: true) != nil, settings.keepHistory else { return }
                history.add(fileURL: url, kind: url.pathExtension.lowercased() == "gif" ? .gif : .video)
            },
            defaultFormat: settings.recordingFormat,
            gifFramesPerSecond: settings.gifFPS
        ))
    }

    func pin(_ image: NSImage) {
        pins.pin(
            image: image,
            onEdit: { [weak self] image in self?.openEditor(image) },
            onCopy: { [weak self] image in
                self?.clipboard.copy(image: image)
                self?.toast.show("Copiado", systemImage: "doc.on.clipboard.fill")
            }
        )
    }

    func openHistoryEntry(_ entry: HistoryEntry, url: URL) {
        switch entry.kind {
        case .image:
            if let image = NSImage(contentsOf: url) {
                openEditor(image)
            }
        case .video:
            // El editor trabaja sobre una copia: borrar o recortar el historial no le quita el archivo.
            guard let copy = try? files.temporaryCopy(of: url, prefix: settings.fileNamePrefix, date: entry.createdAt) else {
                toast.show("No se pudo abrir la grabación", systemImage: "exclamationmark.triangle")
                return
            }
            openVideoEditor(copy)
        case .gif:
            NSWorkspace.shared.open(url)
        }
    }

    func copyHistoryEntry(_ entry: HistoryEntry, url: URL) {
        if entry.kind == .image {
            guard clipboard.copyImageFile(at: url) else {
                toast.show("No se pudo copiar", systemImage: "exclamationmark.triangle")
                return
            }
        } else {
            clipboard.copy(fileURL: url)
        }
        toast.show("Copiado", systemImage: "doc.on.clipboard.fill")
    }

    func reveal(_ url: URL) {
        files.revealInFinder(url)
    }

    // MARK: - Private

    private func showQuickAccess(_ state: QuickAccessState) {
        let item = state.item
        quickAccess.show(item, actions: QuickAccessActions(
            fileURL: { state.savedURL ?? item.fileURL },
            onCopy: { [weak self] in self?.copy(item) },
            onSave: { [weak self] in self?.save(state) },
            onEdit: { [weak self] in self?.edit(item) },
            onPin: item.image.map { image in { [weak self] in self?.pin(image) } }
        ))
    }

    /// Guarda una sola vez por carpeta: pulsar Guardar de nuevo no crea duplicados.
    private func save(_ state: QuickAccessState) {
        if let saved = state.savedURL, files.isInSaveFolder(saved) {
            toast.show("Ya está en \(files.saveFolderDisplayPath)", systemImage: "folder")
            return
        }
        if let saved = saveToFolder(state.item.fileURL, announce: true) {
            state.savedURL = saved
        }
    }

    private func makeGIF(from url: URL) async -> URL? {
        let output = files.temporaryURL(prefix: settings.fileNamePrefix, fileExtension: "gif")
        return try? await GifExporter.export(
            videoURL: url,
            to: output,
            framesPerSecond: settings.gifFPS,
            maxWidth: settings.gifMaxWidth
        )
    }

    private func writeTemporary(_ image: NSImage) -> URL? {
        try? files.writeTemporary(image, format: settings.imageFormat, prefix: settings.fileNamePrefix)
    }

    @discardableResult
    private func saveToFolder(_ url: URL, announce: Bool) -> URL? {
        do {
            let saved = try files.saveToFolder(url)
            if announce {
                toast.show("Guardado en \(files.saveFolderDisplayPath)", systemImage: "checkmark.circle.fill")
            }
            return saved
        } catch {
            toast.show("No se pudo guardar en \(files.saveFolderDisplayPath)", systemImage: "exclamationmark.triangle")
            return nil
        }
    }
}

/// Estado compartido por las acciones de una tarjeta de acceso rapido. `item.fileURL` es siempre el
/// temporal (legible sin bookmark); `savedURL` es la copia en la carpeta de guardado, si existe.
private final class QuickAccessState {
    let item: CaptureItem
    var savedURL: URL?

    init(item: CaptureItem) {
        self.item = item
    }
}
