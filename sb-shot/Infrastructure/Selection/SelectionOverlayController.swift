import AppKit

final class SelectionOverlayController: NSObject {
    private var selectionWindow: SelectionWindow?
    private var completion: ((CGRect?) -> Void)?

    func beginSelection(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion

        let desktopFrame = NSScreen.screens
            .map(\ .frame)
            .reduce(CGRect.null) { $0.union($1) }

        guard !desktopFrame.isNull else {
            finish(with: nil)
            return
        }

        let overlayView = SelectionOverlayView(frame: CGRect(origin: .zero, size: desktopFrame.size))
        overlayView.onSelectionFinished = { [weak self] localRect in
            guard let self else { return }
            let globalRect = localRect.map { $0.offsetBy(dx: desktopFrame.minX, dy: desktopFrame.minY) }
            self.finish(with: globalRect)
        }

        let window = SelectionWindow(
            contentRect: desktopFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.onCancel = { [weak self] in
            self?.finish(with: nil)
        }
        window.contentView = overlayView

        selectionWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlayView)
    }

    private func finish(with rect: CGRect?) {
        guard let completion else { return }
        self.completion = nil
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        completion(rect)
    }
}

private final class SelectionWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class SelectionOverlayView: NSView {
    var onSelectionFinished: ((CGRect?) -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let dimPath = NSBezierPath(rect: bounds)
        if let rect = currentSelectionRect {
            dimPath.appendRect(rect)
            dimPath.windingRule = .evenOdd
        }

        NSColor.black.withAlphaComponent(0.35).setFill()
        dimPath.fill()

        if let rect = currentSelectionRect {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            border.stroke()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        let rect = currentSelectionRect?.standardized.integral
        let isValid = (rect?.width ?? 0) >= 5 && (rect?.height ?? 0) >= 5
        onSelectionFinished?(isValid ? rect : nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        onSelectionFinished?(nil)
    }

    private var currentSelectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
    }
}
