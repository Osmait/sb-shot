import AppKit

protocol PreviewPresenting: AnyObject {
    func show(image: NSImage, onCopy: @escaping () -> Void, onEdit: @escaping () -> Void)
}

protocol ThumbnailPresenting: AnyObject {
    func show(image: NSImage, onOpen: @escaping () -> Void, onEdit: @escaping () -> Void, onCopy: @escaping () -> Void)
}

protocol EditorPresenting: AnyObject {
    func show(image: NSImage, onCopy: @escaping (NSImage) -> Void)
}
