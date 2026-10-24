import AppKit
import SwiftUI

/// Draggable surface for dropping a file into other apps, which also responds to clicks
/// and horizontal swipes (to dismiss).
struct FileDragSource: NSViewRepresentable {
    let fileURL: () -> URL?
    let previewImage: NSImage?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    var onSwipe: (() -> Void)?

    func makeNSView(context _: Context) -> FileDragSourceView {
        let view = FileDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: FileDragSourceView, context _: Context) {
        update(view)
    }

    private func update(_ view: FileDragSourceView) {
        view.fileURL = fileURL
        view.previewImage = previewImage
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.onDragEnded = onDragEnded
        view.onSwipe = onSwipe
    }
}

/// Hosting view for floating panels that don't activate the app: the first click already presses the button.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

final class FileDragSourceView: NSView, NSDraggingSource {
    var fileURL: (() -> URL?)?
    var previewImage: NSImage?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragEnded: ((Bool) -> Void)?
    var onSwipe: (() -> Void)?

    private var mouseDownPoint: CGPoint?
    private var didStartDrag = false
    private var swipeDistance: CGFloat = 0

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didStartDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4, let url = fileURL?() else { return }

        didStartDrag = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = previewImage ?? NSWorkspace.shared.icon(forFile: url.path)
        let size = Self.dragSize(for: image.size)
        item.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), contents: image)

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        if !didStartDrag {
            if event.clickCount >= 2, let onDoubleClick {
                onDoubleClick()
            } else {
                onClick?()
            }
        }
        mouseDownPoint = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard onSwipe != nil, event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }

        if event.phase == .began {
            swipeDistance = 0
        }
        swipeDistance += event.scrollingDeltaX

        if abs(swipeDistance) > 60, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            swipeDistance = 0
            onSwipe?()
        }
    }

    func draggingSession(_: NSDraggingSession, sourceOperationMaskFor _: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation: NSDragOperation) {
        onDragEnded?(operation != [])
    }

    private static func dragSize(for size: CGSize) -> CGSize {
        let maxSide: CGFloat = 160
        let ratio = min(maxSide / max(size.width, 1), maxSide / max(size.height, 1), 1)
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }
}
