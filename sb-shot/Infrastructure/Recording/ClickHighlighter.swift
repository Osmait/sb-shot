import AppKit
import QuartzCore

/// Dibuja un circulo animado en cada clic mientras se graba. Sus ventanas si aparecen en el video.
final class ClickHighlighter {
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []

    /// Ventanas que deben aparecer en la grabacion.
    var windowNumbers: [Int] {
        windows.map(\.windowNumber)
    }

    func start() {
        stop()

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: false)

            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }

        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            self?.ripple(at: NSEvent.mouseLocation)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.ripple(at: NSEvent.mouseLocation)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()

        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func ripple(at point: CGPoint) {
        guard
            let window = windows.first(where: { $0.frame.contains(point) }),
            let layer = window.contentView?.layer
        else { return }

        let radius: CGFloat = 22
        let local = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)

        let circle = CAShapeLayer()
        circle.frame = CGRect(x: local.x - radius, y: local.y - radius, width: radius * 2, height: radius * 2)
        circle.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
        circle.fillColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        circle.strokeColor = NSColor.systemYellow.withAlphaComponent(0.9).cgColor
        circle.lineWidth = 2.5
        layer.addSublayer(circle)

        CATransaction.begin()
        CATransaction.setCompletionBlock { circle.removeFromSuperlayer() }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.3

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.5
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        circle.add(group, forKey: "ripple")

        CATransaction.commit()
    }
}
