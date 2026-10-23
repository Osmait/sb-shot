import AppKit

struct QuickAccessActions {
    /// Archivo actual para arrastrar (la copia guardada, si ya se guardo).
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
    /// Reciben el archivo ya exportado (MP4 o GIF).
    let onCopy: (URL) -> Void
    let onSave: (URL) -> Void
    /// Valores iniciales del panel de exportacion, tomados de los ajustes.
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
    /// Muestra el borde y la barra de control (la grabacion excluye todas las ventanas de la app).
    func show(for selection: ScreenSelection, onStop: @escaping () -> Void, onRestart: @escaping () -> Void, onCancel: @escaping () -> Void)
    func update(elapsed: TimeInterval)
    func hide()
}
