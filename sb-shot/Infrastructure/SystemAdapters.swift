import AppKit

@MainActor
final class SelectionOverlayRegionSelector: RegionSelecting {
    private let capturer: ScreenCaptureProviding
    private var activeController: SelectionOverlayController?

    init(capturer: ScreenCaptureProviding) {
        self.capturer = capturer
    }

    func select(options: SelectionOptions) async -> SelectionResult? {
        guard activeController == nil else { return nil }

        let needsSnapshots = options.freezeScreen || options.showsMagnifier
        let snapshots = await needsSnapshots ? ((try? capturer.displaySnapshots()) ?? [:]) : [:]

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
