import AppKit

@MainActor
final class SelectionOverlayRegionSelector: RegionSelecting {
    private let capturer: ScreenCaptureProviding
    private var activeController: SelectionOverlayController?
    /// Se marca antes de esperar las capturas para que dos atajos seguidos no abran dos overlays.
    private var isSelecting = false

    init(capturer: ScreenCaptureProviding) {
        self.capturer = capturer
    }

    func select(options: SelectionOptions) async -> SelectionResult? {
        guard !isSelecting else { return nil }
        isSelecting = true
        defer { isSelecting = false }

        let needsSnapshots = options.freezeScreen || options.showsMagnifier
        // Los iconos del escritorio solo se ocultan en la imagen congelada; la lupa muestra la pantalla real.
        let hidesIcons = options.freezeScreen && options.hidesDesktopIcons
        let snapshots = await needsSnapshots
            ? ((try? capturer.displaySnapshots(hidingDesktopIcons: hidesIcons)) ?? [:])
            : [:]

        var effectiveOptions = options
        if snapshots.isEmpty {
            effectiveOptions.freezeScreen = false
        }

        return await withCheckedContinuation { continuation in
            let controller = SelectionOverlayController()
            activeController = controller
            controller.beginSelection(options: effectiveOptions, snapshots: snapshots) { result in
                self.activeController = nil
                continuation.resume(returning: result)
            }
        }
    }

    func displayUnderCursor() -> ScreenSelection? {
        guard
            let screen = ScreenGeometry.screenUnderCursor,
            let displayID = ScreenGeometry.displayID(of: screen)
        else { return nil }
        return .display(id: displayID, frame: screen.frame)
    }
}

/// Activa sb-shot para recibir el teclado y despues devuelve el foco a la app que estaba al frente.
@MainActor
enum AppFocus {
    /// `frontmostApplication` tarda en reflejar una reactivacion; se recuerda un momento la app devuelta.
    private static var recentlyRestored: (app: NSRunningApplication, date: Date)?

    /// Activa la app y devuelve la app externa que estaba al frente, para pasarla despues a `restore`.
    static func activate() -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var previous = NSWorkspace.shared.frontmostApplication
        if previous?.processIdentifier == ownPID {
            previous = nil
            if let recent = recentlyRestored, Date().timeIntervalSince(recent.date) < 1 {
                previous = recent.app
            }
        }
        recentlyRestored = nil
        NSApp.activate()
        return previous
    }

    static func restore(_ app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        recentlyRestored = (app, Date())
        app.activate()
    }
}

@MainActor
final class EditorWindowPresenter: EditorPresenting {
    private var controllers: [CaptureEditorWindowController] = []

    func show(image: NSImage, actions: EditorActions) {
        let editor = CaptureEditorWindowController(image: image, actions: actions)
        editor.onClose = { [weak self, weak editor] in
            self?.controllers.removeAll { $0 === editor }
        }
        controllers.append(editor)
        editor.show()
    }
}

@MainActor
final class VideoEditorWindowPresenter: VideoEditorPresenting {
    private var controllers: [VideoEditorWindowController] = []

    func show(videoURL: URL, actions: VideoEditorActions) {
        let editor = VideoEditorWindowController(videoURL: videoURL, actions: actions)
        editor.onClose = { [weak self, weak editor] in
            self?.controllers.removeAll { $0 === editor }
        }
        controllers.append(editor)
        editor.show()
    }
}
