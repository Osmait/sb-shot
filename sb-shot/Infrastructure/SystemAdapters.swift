import AppKit

@MainActor
final class SelectionOverlayRegionSelector: RegionSelecting {
    private let capturer: ScreenCaptureProviding
    private var activeController: SelectionOverlayController?
    /// Set before awaiting the snapshots so two shortcuts in a row don't open two overlays.
    private var isSelecting = false

    init(capturer: ScreenCaptureProviding) {
        self.capturer = capturer
    }

    func select(options: SelectionOptions) async -> SelectionResult? {
        guard !isSelecting else { return nil }
        isSelecting = true
        defer { isSelecting = false }

        let needsSnapshots = options.freezeScreen || options.showsMagnifier
        // Desktop icons are only hidden in the frozen image; the magnifier shows the real screen.
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

/// Activates sb-shot to receive keyboard input and then returns focus to the app that was frontmost.
@MainActor
enum AppFocus {
    /// `frontmostApplication` is slow to reflect a reactivation; the restored app is remembered briefly.
    private static var recentlyRestored: (app: NSRunningApplication, date: Date)?

    /// Activates the app and returns the external app that was frontmost, to pass later to `restore`.
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
