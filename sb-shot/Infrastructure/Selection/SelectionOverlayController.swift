import AppKit

/// Another app's window that can be picked in window mode. `frame` is in AppKit global coordinates.
struct OverlayWindowInfo {
    let id: CGWindowID
    let frame: CGRect
    let ownerName: String?

    /// Visible windows of other apps, ordered from front to back.
    static func onScreenWindows() -> [OverlayWindowInfo] {
        guard
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let pid = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { info in
            guard
                (info[kCGWindowLayer as String] as? Int) == 0,
                (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let boundsInfo = info[kCGWindowBounds as String],
                let bounds = CGRect(dictionaryRepresentation: boundsInfo as! CFDictionary), // swiftlint:disable:this force_cast
                bounds.width >= 40, bounds.height >= 40
            else { return nil }

            return OverlayWindowInfo(
                id: id,
                frame: ScreenGeometry.toAppKit(bounds),
                ownerName: info[kCGWindowOwnerName as String] as? String
            )
        }
    }
}

/// State shared by the overlay windows (one per display).
final class SelectionSession {
    let options: SelectionOptions
    let windows: [OverlayWindowInfo]

    /// Windows only ("Capture Window" action). Otherwise the mode is smart:
    /// dragging selects an area, clicking picks the window or display under the cursor.
    let isWindowOnly: Bool
    var mouseLocation = NSEvent.mouseLocation
    var dragStart: CGPoint?
    var dragCurrent: CGPoint?
    var dragScreenFrame: CGRect?
    var isMovingSelection = false
    var isSquare = false

    init(options: SelectionOptions, windows: [OverlayWindowInfo]) {
        self.options = options
        self.windows = windows
        isWindowOnly = options.startInWindowMode && options.allowsWindowMode
    }

    var isDragging: Bool {
        dragStart != nil
    }

    /// An area is in progress (the drag has already exceeded the click threshold).
    var isSelectingArea: Bool {
        guard !isWindowOnly, let rect = selectionRect else { return false }
        return rect.width > 4 || rect.height > 4
    }

    var hoveredWindow: OverlayWindowInfo? {
        windows.first { $0.frame.contains(mouseLocation) }
    }

    /// What a click would pick: the window under the cursor or, on the desktop, the full display.
    var clickTarget: ScreenSelection? {
        guard options.allowsWindowMode else { return nil }
        if let window = hoveredWindow {
            return .window(id: window.id, frame: window.frame)
        }
        guard !isWindowOnly,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let displayID = ScreenGeometry.displayID(of: screen)
        else { return nil }
        return .display(id: displayID, frame: screen.frame)
    }

    /// Selected rectangle in global coordinates, clamped to the display where the drag started.
    var selectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }

        var current = dragCurrent
        if isSquare {
            let side = max(abs(current.x - dragStart.x), abs(current.y - dragStart.y))
            current = CGPoint(
                x: dragStart.x + (current.x >= dragStart.x ? side : -side),
                y: dragStart.y + (current.y >= dragStart.y ? side : -side)
            )
        }

        var rect = CGRect.spanning(dragStart, current)
        if let dragScreenFrame {
            rect = rect.intersection(dragScreenFrame)
        }
        return rect.isNull ? nil : rect
    }

    var hint: String {
        let prefix = switch options.purpose {
        case .screenshot: ""
        case .recording: String(localized: "Record") + "  ·  "
        case .text: String(localized: "Recognize Text") + "  ·  "
        }
        if isWindowOnly {
            return prefix + String(localized: "Click a window  ·  Enter: fullscreen  ·  Esc: cancel")
        }
        if options.allowsWindowMode {
            return prefix + String(localized: "Drag: area  ·  Click: window  ·  Click the desktop or Enter: fullscreen  ·  Esc: cancel")
        }
        return prefix + String(localized: "Drag to select  ·  Enter: fullscreen  ·  Esc: cancel")
    }
}

final class SelectionOverlayController: NSObject {
    private var windows: [SelectionWindow] = []
    private var overlayViews: [SelectionOverlayView] = []
    private var monitors: [Any] = []
    private var session: SelectionSession?
    private var snapshots: [CGDirectDisplayID: CGImage] = [:]
    private var completion: ((SelectionResult?) -> Void)?
    /// App that had focus before the overlay; focus is returned to it when done.
    private var previousApp: NSRunningApplication?
    /// Regions (global coordinates) drawn in the last refresh, so the display being left is repainted too.
    private var lastDirtyRects: [CGRect] = []

    func beginSelection(
        options: SelectionOptions,
        snapshots: [CGDirectDisplayID: CGImage],
        completion: @escaping (SelectionResult?) -> Void
    ) {
        self.completion = completion
        self.snapshots = snapshots

        let session = SelectionSession(options: options, windows: options.allowsWindowMode ? OverlayWindowInfo.onScreenWindows() : [])
        self.session = session

        for screen in NSScreen.screens {
            let displayID = ScreenGeometry.displayID(of: screen)
            let snapshot = displayID.flatMap { snapshots[$0] }
            let window = makeWindow(for: screen, snapshot: snapshot, session: session)
            windows.append(window)
        }

        installMonitors()

        previousApp = AppFocus.activate()
        let keyScreen = ScreenGeometry.screenUnderCursor
        for window in windows {
            if window.screenFrame == keyScreen?.frame {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
        }
        NSCursor.crosshair.set()
    }

    // MARK: - Window setup

    private func makeWindow(for screen: NSScreen, snapshot: CGImage?, session: SelectionSession) -> SelectionWindow {
        let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.screenFrame = screen.frame
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: false)

        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        if session.options.freezeScreen, let snapshot {
            container.layer?.contents = snapshot
            container.layer?.contentsGravity = .resize
        }

        let overlay = SelectionOverlayView(frame: container.bounds, screenFrame: screen.frame, snapshot: snapshot, session: session)
        overlay.autoresizingMask = [.width, .height]
        overlay.onChange = { [weak self] in self?.refreshAll() }
        overlay.onFinish = { [weak self] selection in self?.finish(with: selection) }
        overlay.onCancel = { [weak self] in self?.finish(with: nil) }
        container.addSubview(overlay)

        window.contentView = container
        overlayViews.append(overlay)
        return window
    }

    private func installMonitors() {
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil
        }
        if let keyMonitor {
            monitors.append(keyMonitor)
        }
    }

    private func handle(_ event: NSEvent) {
        guard let session else { return }

        switch event.type {
        case .flagsChanged:
            session.isSquare = event.modifierFlags.contains(.shift)
            refreshAll()

        case .keyDown:
            switch event.keyCode {
            case 53:
                finish(with: nil)
            case 49 where !event.isARepeat && session.isDragging:
                session.isMovingSelection = true
            case 36, 76:
                finishWithScreenUnderCursor()
            default:
                break
            }

        case .keyUp where event.keyCode == 49:
            session.isMovingSelection = false

        default:
            break
        }
    }

    /// Repaints only the displays affected by the current or previous state (cursor, selection, click target).
    private func refreshAll() {
        guard let session else { return }

        var dirty = [CGRect(x: session.mouseLocation.x - 1, y: session.mouseLocation.y - 1, width: 2, height: 2)]
        if session.isDragging, let dragScreenFrame = session.dragScreenFrame {
            dirty.append(dragScreenFrame)
        }
        if !session.isSelectingArea, let target = session.clickTarget {
            dirty.append(target.frame)
        }

        let affected = dirty + lastDirtyRects
        lastDirtyRects = dirty
        for view in overlayViews where affected.contains(where: { $0.intersects(view.screenFrame) }) {
            view.needsDisplay = true
        }
    }

    // MARK: - Finish

    private func finishWithScreenUnderCursor() {
        guard
            let screen = ScreenGeometry.screenUnderCursor,
            let displayID = ScreenGeometry.displayID(of: screen)
        else { return }
        finish(with: .display(id: displayID, frame: screen.frame))
    }

    private func finish(with selection: ScreenSelection?) {
        guard let completion else { return }
        self.completion = nil

        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
        overlayViews.removeAll()
        lastDirtyRects.removeAll()
        NSCursor.arrow.set()
        AppFocus.restore(previousApp)
        previousApp = nil

        guard let selection else {
            completion(nil)
            return
        }

        let frozen = session?.options.freezeScreen == true ? frozenImage(for: selection) : nil
        session = nil
        completion(SelectionResult(selection: selection, frozenImage: frozen))
    }

    private func frozenImage(for selection: ScreenSelection) -> NSImage? {
        let rect: CGRect
        switch selection {
        case let .area(area): rect = area
        case let .display(_, frame): rect = frame
        case .window: return nil
        }

        guard
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) && $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
            let displayID = ScreenGeometry.displayID(of: screen),
            let snapshot = snapshots[displayID]
        else { return nil }

        let clipped = rect.intersection(screen.frame)
        let scale = CGFloat(snapshot.width) / screen.frame.width
        let local = clipped.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let pixelRect = CGRect(
            x: local.minX * scale,
            y: (screen.frame.height - local.maxY) * scale,
            width: local.width * scale,
            height: local.height * scale
        ).integral

        guard let cropped = snapshot.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: clipped.size)
    }
}

// MARK: - Window

private final class SelectionWindow: NSWindow {
    var screenFrame: CGRect = .zero

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

// MARK: - Overlay view

private final class SelectionOverlayView: NSView {
    var onChange: (() -> Void)?
    var onFinish: ((ScreenSelection) -> Void)?
    var onCancel: (() -> Void)?

    let screenFrame: CGRect
    private let snapshot: CGImage?
    private let session: SelectionSession

    init(frame: CGRect, screenFrame: CGRect, snapshot: CGImage?, session: SelectionSession) {
        self.screenFrame = screenFrame
        self.snapshot = snapshot
        self.session = session
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with _: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: Events

    private func globalPoint(for event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x + screenFrame.minX, y: local.y + screenFrame.minY)
    }

    override func mouseMoved(with event: NSEvent) {
        session.mouseLocation = globalPoint(for: event)
        NSCursor.crosshair.set()
        onChange?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = globalPoint(for: event)
        session.mouseLocation = point

        guard !session.isWindowOnly else { return }
        session.dragStart = point
        session.dragCurrent = point
        session.dragScreenFrame = screenFrame
        onChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = globalPoint(for: event)

        if session.isMovingSelection, let start = session.dragStart, let current = session.dragCurrent {
            let dx = point.x - current.x
            let dy = point.y - current.y
            session.dragStart = CGPoint(x: start.x + dx, y: start.y + dy)
        }

        session.mouseLocation = point
        session.dragCurrent = point
        onChange?()
    }

    override func mouseUp(with event: NSEvent) {
        session.mouseLocation = globalPoint(for: event)

        let rect = session.isWindowOnly ? nil : session.selectionRect?.integral
        session.dragStart = nil
        session.dragCurrent = nil
        session.isMovingSelection = false

        if let rect, rect.width >= 5, rect.height >= 5 {
            onFinish?(.area(rect))
        } else if let target = session.clickTarget {
            // A click without dragging picks the window or display under the cursor.
            onFinish?(target)
        } else {
            onChange?()
        }
    }

    override func rightMouseDown(with _: NSEvent) {
        onCancel?()
    }

    // MARK: Drawing

    private func toLocal(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private var localMouse: CGPoint? {
        guard screenFrame.contains(session.mouseLocation) else { return nil }
        return CGPoint(x: session.mouseLocation.x - screenFrame.minX, y: session.mouseLocation.y - screenFrame.minY)
    }

    override func draw(_: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let target = session.isSelectingArea ? nil : session.clickTarget
        if let target {
            drawClickTarget(target, in: context)
        } else {
            drawAreaMode(context)
        }

        if let mouse = localMouse {
            if !session.isDragging, target == nil || session.hoveredWindow == nil, !session.isWindowOnly, session.options.showsCrosshair {
                drawCrosshair(at: mouse, in: context)
            }
            if !session.isWindowOnly, session.options.showsMagnifier, let snapshot {
                drawMagnifier(at: mouse, snapshot: snapshot, in: context)
            }
            if !session.isDragging {
                drawHint(in: context)
            }
        }
    }

    private func drawAreaMode(_ context: CGContext) {
        let selection = session.selectionRect.map(toLocal).flatMap { $0.intersects(bounds) ? $0 : nil }

        context.saveGState()
        context.addRect(bounds)
        if let selection {
            context.addRect(selection)
        }
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        guard let selection, let rect = session.selectionRect else { return }

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(1)
        context.stroke(selection.insetBy(dx: -0.5, dy: -0.5))

        drawDimensionLabel("\(Int(rect.width)) × \(Int(rect.height))", below: selection, in: context)
    }

    /// Highlights what a click would pick: the rest is dimmed and the target gets an accent border.
    private func drawClickTarget(_ target: ScreenSelection, in context: CGContext) {
        let frame = toLocal(target.frame).intersection(bounds)
        let isOnThisScreen = !frame.isNull && !frame.isEmpty

        context.saveGState()
        context.addRect(bounds)
        if isOnThisScreen {
            context.addRect(frame)
        }
        context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        guard isOnThisScreen else { return }

        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
        context.fill(frame)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(3)
        context.stroke(frame.insetBy(dx: 1.5, dy: 1.5))

        let label: String
        switch target {
        case .window:
            let name = session.hoveredWindow?.ownerName.map { "\($0)  ·  " } ?? String(localized: "Window") + "  ·  "
            label = "\(name)\(Int(target.frame.width)) × \(Int(target.frame.height))"
        case .display, .area:
            label = String(localized: "Fullscreen") + "  ·  \(Int(target.frame.width)) × \(Int(target.frame.height))"
        }
        drawPill(label, centeredAt: CGPoint(x: frame.midX, y: frame.midY), in: context, fontSize: 13)
    }

    private func drawCrosshair(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setLineWidth(1)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        context.setShadow(offset: .zero, blur: 1, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        context.move(to: CGPoint(x: bounds.minX, y: point.y.rounded() + 0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: point.y.rounded() + 0.5))
        context.move(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.minY))
        context.addLine(to: CGPoint(x: point.x.rounded() + 0.5, y: bounds.maxY))
        context.strokePath()
        context.restoreGState()
    }

    private func drawMagnifier(at point: CGPoint, snapshot: CGImage, in context: CGContext) {
        let samples = 15
        let cell: CGFloat = 8
        let size = CGFloat(samples) * cell
        let scale = CGFloat(snapshot.width) / max(bounds.width, 1)

        let centerX = Int(point.x * scale)
        let centerY = Int((bounds.height - point.y) * scale)
        let half = samples / 2
        let originX = min(max(centerX - half, 0), snapshot.width - samples)
        let originY = min(max(centerY - half, 0), snapshot.height - samples)
        guard let crop = snapshot.cropping(to: CGRect(x: originX, y: originY, width: samples, height: samples)) else { return }

        let labelHeight: CGFloat = 22
        var origin = CGPoint(x: point.x + 24, y: point.y - 24 - size - labelHeight)
        if origin.x + size > bounds.maxX - 8 {
            origin.x = point.x - 24 - size
        }
        if origin.y < bounds.minY + 8 {
            origin.y = point.y + 24
        }
        let loupe = CGRect(origin: CGPoint(x: origin.x, y: origin.y + labelHeight), size: CGSize(width: size, height: size))
        let loupePath = CGPath(roundedRect: loupe, cornerWidth: 12, cornerHeight: 12, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addPath(loupePath)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(loupePath)
        context.clip()
        context.interpolationQuality = .none
        context.draw(crop, in: loupe)

        context.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(0.5)
        for index in 1 ..< samples {
            let offset = CGFloat(index) * cell
            context.move(to: CGPoint(x: loupe.minX + offset, y: loupe.minY))
            context.addLine(to: CGPoint(x: loupe.minX + offset, y: loupe.maxY))
            context.move(to: CGPoint(x: loupe.minX, y: loupe.minY + offset))
            context.addLine(to: CGPoint(x: loupe.maxX, y: loupe.minY + offset))
        }
        context.strokePath()

        let centerCell = CGRect(
            x: loupe.minX + CGFloat(centerX - originX) * cell,
            y: loupe.maxY - CGFloat(centerY - originY + 1) * cell,
            width: cell,
            height: cell
        )
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.stroke(centerCell)
        context.restoreGState()

        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(2)
        context.addPath(loupePath)
        context.strokePath()

        let topLeftY = Int(ScreenGeometry.primaryScreenHeight - session.mouseLocation.y)
        var label = "\(Int(session.mouseLocation.x)), \(topLeftY)"
        if let hex = hexColor(in: snapshot, x: centerX, y: centerY) {
            label += "   \(hex)"
        }
        drawPill(label, centeredAt: CGPoint(x: loupe.midX, y: origin.y + labelHeight / 2 - 2), in: context, fontSize: 11)
    }

    private func hexColor(in image: CGImage, x: Int, y: Int) -> String? {
        guard
            x >= 0, y >= 0, x < image.width, y < image.height,
            let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }

        var data = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &data,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return String(format: "#%02X%02X%02X", data[0], data[1], data[2])
    }

    private func drawDimensionLabel(_ text: String, below rect: CGRect, in context: CGContext) {
        var center = CGPoint(x: rect.midX, y: rect.minY - 18)
        if center.y < bounds.minY + 14 {
            center.y = rect.minY + 18
        }
        drawPill(text, centeredAt: center, in: context, fontSize: 12)
    }

    private func drawHint(in context: CGContext) {
        drawPill(session.hint, centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - 60), in: context, fontSize: 12)
    }

    private func drawPill(_ text: String, centeredAt center: CGPoint, in context: CGContext, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let size = string.size(withAttributes: attributes)
        let pill = CGRect(
            x: center.x - size.width / 2 - 10,
            y: center.y - size.height / 2 - 4,
            width: size.width + 20,
            height: size.height + 8
        )

        context.saveGState()
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        context.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        context.fillPath()
        context.restoreGState()

        string.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 4), withAttributes: attributes)
    }
}
