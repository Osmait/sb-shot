import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Decide que hacer con cada captura o grabacion segun los ajustes, y ejecuta las acciones
/// del acceso rapido, el editor y el historial.
@MainActor
final class CaptureOutputHandler {
    private let settings: AppSettings
    private let clipboard: ClipboardWriting
    private let files: FileStorage
    private let history: HistoryStore
    private let quickAccess: QuickAccessPresenting
    private let editor: EditorPresenting
    private let videoEditor: VideoEditorPresenting
    private let pins: PinPresenting
    private let toast: ToastPresenting

    init(
        settings: AppSettings,
        clipboard: ClipboardWriting,
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

        guard let fileURL = try? files.writeTemporary(image, format: settings.imageFormat, prefix: settings.fileNamePrefix) else {
            toast.show("No se pudo guardar la captura", systemImage: "exclamationmark.triangle")
            return
        }

        var item = CaptureItem(content: .image(image), thumbnail: image, fileURL: fileURL)

        if settings.copyToClipboard {
            clipboard.copy(image: image)
        }
        if settings.autoSave, let saved = saveToFolder(fileURL, announce: false) {
            item.fileURL = saved
        }
        if settings.keepHistory {
            history.add(fileURL: fileURL, kind: .image)
        }

        if settings.openEditorAfterCapture {
            openEditor(image)
        } else if settings.showQuickAccess {
            showQuickAccess(item)
        } else {
            toast.show(settings.copyToClipboard ? "Captura copiada" : "Captura lista", systemImage: "checkmark.circle.fill")
        }
    }

    func handleRecording(_ rawURL: URL) async {
        let videoURL = files.temporaryURL(prefix: settings.fileNamePrefix, fileExtension: "mp4")
        let sourceURL = (try? FileManager.default.moveItem(at: rawURL, to: videoURL)) != nil ? videoURL : rawURL
        let thumbnail = await VideoExporter.thumbnail(for: sourceURL) ?? NSWorkspace.shared.icon(for: .mpeg4Movie)

        var item: CaptureItem
        if settings.recordingFormat == .gif {
            toast.showProgress("Creando GIF…")
            guard let gifURL = await makeGIF(from: sourceURL, range: nil) else {
                toast.show("No se pudo crear el GIF", systemImage: "exclamationmark.triangle")
                return
            }
            toast.hide()
            item = CaptureItem(content: .gif(gifURL), thumbnail: thumbnail, fileURL: gifURL)
        } else {
            item = CaptureItem(content: .video(sourceURL), thumbnail: thumbnail, fileURL: sourceURL)
        }

        if settings.autoSave, let saved = saveToFolder(item.fileURL, announce: false) {
            item.fileURL = saved
        }
        if settings.keepHistory {
            history.add(fileURL: item.fileURL, kind: item.videoURL != nil ? .video : .gif)
        }

        if settings.showQuickAccess {
            showQuickAccess(item)
        } else {
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
            clipboard.copy(image: image)
        } else {
            clipboard.copy(fileURL: item.fileURL)
        }
        toast.show("Copiado", systemImage: "doc.on.clipboard.fill")
    }

    func save(_ item: CaptureItem) {
        if item.fileURL.path.hasPrefix(files.saveFolder.path) {
            toast.show("Ya está en \(files.saveFolderDisplayPath)", systemImage: "folder")
            return
        }
        saveToFolder(item.fileURL, announce: true)
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
                if files.saveWithPanel(url) != nil {
                    toast.show("Guardado", systemImage: "checkmark.circle.fill")
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
                self?.toast.show("Video copiado", systemImage: "doc.on.clipboard.fill")
            },
            onSave: { [weak self] url in
                self?.saveToFolder(url, announce: true)
            },
            onExportGIF: { [weak self] url, range in
                Task { await self?.exportGIF(from: url, range: range) }
            }
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
            openVideoEditor(url)
        case .gif:
            NSWorkspace.shared.open(url)
        }
    }

    func copyHistoryEntry(_ entry: HistoryEntry, url: URL) {
        if entry.kind == .image, let image = NSImage(contentsOf: url) {
            clipboard.copy(image: image)
        } else {
            clipboard.copy(fileURL: url)
        }
        toast.show("Copiado", systemImage: "doc.on.clipboard.fill")
    }

    func reveal(_ url: URL) {
        files.revealInFinder(url)
    }

    // MARK: - Private

    private func showQuickAccess(_ item: CaptureItem) {
        quickAccess.show(item, actions: QuickAccessActions(
            onCopy: { [weak self] in self?.copy(item) },
            onSave: { [weak self] in self?.save(item) },
            onEdit: { [weak self] in self?.edit(item) },
            onPin: item.image.map { image in { [weak self] in self?.pin(image) } }
        ))
    }

    private func exportGIF(from url: URL, range: CMTimeRangeValue?) async {
        toast.showProgress("Creando GIF…")
        guard let gifURL = await makeGIF(from: url, range: range) else {
            toast.show("No se pudo crear el GIF", systemImage: "exclamationmark.triangle")
            return
        }
        toast.hide()

        let thumbnail = await VideoExporter.thumbnail(for: url) ?? NSWorkspace.shared.icon(for: .gif)
        var item = CaptureItem(content: .gif(gifURL), thumbnail: thumbnail, fileURL: gifURL)
        if let saved = saveToFolder(gifURL, announce: false) {
            item.fileURL = saved
        }
        if settings.keepHistory {
            history.add(fileURL: gifURL, kind: .gif)
        }
        showQuickAccess(item)
    }

    private func makeGIF(from url: URL, range: CMTimeRangeValue?) async -> URL? {
        let output = files.temporaryURL(prefix: settings.fileNamePrefix, fileExtension: "gif")
        let timeRange = range.map {
            CMTimeRange(
                start: CMTime(seconds: $0.start, preferredTimescale: 600),
                duration: CMTime(seconds: $0.duration, preferredTimescale: 600)
            )
        }
        return try? await GifExporter.export(
            videoURL: url,
            to: output,
            framesPerSecond: settings.gifFPS,
            maxWidth: settings.gifMaxWidth,
            timeRange: timeRange
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
