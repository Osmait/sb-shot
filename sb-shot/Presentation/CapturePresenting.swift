import AppKit

struct QuickAccessActions {
    /// Current file to drag (the saved copy, if it was already saved).
    let fileURL: () -> URL
    let onCopy: () -> Void
    let onSave: () -> Void
    let onEdit: () -> Void
    let onPin: (() -> Void)?
}

struct EditorActions {
    let onCopy: (NSImage) -> Void
    let onSave: (NSImage) -> Void
    let onSaveAs: (NSImage) -> Void
    let onPin: (NSImage) -> Void
}

struct VideoEditorActions {
    /// Receive the already exported file (MP4 or GIF).
    let onCopy: (URL) -> Void
    let onSave: (URL) -> Void
    /// Initial values for the export panel, taken from the settings.
    let defaultFormat: RecordingFormat
    let gifFramesPerSecond: Int
}

protocol QuickAccessPresenting: AnyObject {
    func show(_ item: CaptureItem, actions: QuickAccessActions)
    func dismiss(itemID: UUID)
}

protocol EditorPresenting: AnyObject {
    func show(image: NSImage, actions: EditorActions)
}

protocol VideoEditorPresenting: AnyObject {
    func show(videoURL: URL, actions: VideoEditorActions)
}

protocol PinPresenting: AnyObject {
    func pin(image: NSImage, onEdit: @escaping (NSImage) -> Void, onCopy: @escaping (NSImage) -> Void)
}

protocol ToastPresenting: AnyObject {
    func show(_ message: String, systemImage: String)
    func showProgress(_ message: String)
    func hide()
}

protocol HistoryPresenting: AnyObject {
    func show()
}

protocol RecordingControlsPresenting: AnyObject {
    /// Shows the border and the control bar (the recording excludes all app windows).
    func show(for selection: ScreenSelection, onStop: @escaping () -> Void, onRestart: @escaping () -> Void, onCancel: @escaping () -> Void)
    func update(elapsed: TimeInterval)
    func hide()
}
