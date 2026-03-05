import AppKit

@MainActor
final class SelectionOverlayRegionSelector: RegionSelecting {
    private var activeController: SelectionOverlayController?

    func selectRegion() async -> CGRect? {
        await withCheckedContinuation { continuation in
            let controller = SelectionOverlayController()
            activeController = controller
            controller.beginSelection { rect in
                self.activeController = nil
                continuation.resume(returning: rect)
            }
        }
    }
}

@MainActor
final class PreviewWindowPresenter: PreviewPresenting {
    private var controller: CapturePreviewWindowController?

    func show(image: NSImage, onCopy: @escaping () -> Void, onEdit: @escaping () -> Void) {
        controller?.close()

        let preview = CapturePreviewWindowController(
            image: image,
            onCopy: onCopy,
            onEdit: onEdit,
            onClose: { [weak self] in
                self?.controller = nil
            }
        )

        controller = preview
        preview.show()
    }
}

@MainActor
final class ThumbnailWindowPresenter: ThumbnailPresenting {
    private var controller: CaptureThumbnailController?

    func show(image: NSImage, onOpen: @escaping () -> Void, onEdit: @escaping () -> Void, onCopy: @escaping () -> Void) {
        controller?.close()

        let thumbnail = CaptureThumbnailController(
            image: image,
            onOpen: onOpen,
            onEdit: onEdit,
            onCopy: onCopy,
            onClose: { [weak self] in
                self?.controller = nil
            }
        )

        controller = thumbnail
        thumbnail.show()
    }
}

@MainActor
final class EditorWindowPresenter: EditorPresenting {
    private var controller: CaptureEditorWindowController?

    func show(image: NSImage, onCopy: @escaping (NSImage) -> Void) {
        controller?.close()

        let editor = CaptureEditorWindowController(
            image: image,
            onCopy: onCopy,
            onClose: { [weak self] in
                self?.controller = nil
            }
        )

        controller = editor
        editor.show()
    }
}
