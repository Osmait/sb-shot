import AppKit

/// The menu bar glyph: a monochrome version of the app icon (a window with a highlighted area and an arrow).
/// It's a template image, so macOS draws it black or white to match the menu bar.
enum MenuBarIcon {
    /// Menu bar extras are drawn at 18 × 18 points.
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // The glyph is designed on a 24-point grid.
            let scale = rect.width / 24
            context.scaleBy(x: scale, y: scale)
            draw(in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "sb-shot"
        return image
    }()

    private static func draw(in context: CGContext) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)

        // Window with the three title bar dots.
        context.setLineWidth(1.7)
        context.addPath(CGPath(roundedRect: CGRect(x: 4, y: 3, width: 18, height: 14.5), cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.strokePath()
        for x in [7, 9.7, 12.4] {
            context.fillEllipse(in: CGRect(x: x - 0.95, y: 6.2 - 0.95, width: 1.9, height: 1.9))
        }

        // Highlighted area.
        context.setLineWidth(1.6)
        context.addPath(CGPath(roundedRect: CGRect(x: 13, y: 10, width: 6, height: 4.5), cornerWidth: 1, cornerHeight: 1, transform: nil))
        context.strokePath()

        // Gap around the arrow where it crosses the window's border, so both read at 18 points.
        // It stops short of the head so it doesn't cut into the highlighted area.
        let tail = CGPoint(x: 2, y: 22)
        let tip = CGPoint(x: 11.2, y: 12.8)
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(4.4)
        context.move(to: tail)
        context.addLine(to: CGPoint(x: 8.6, y: 15.4))
        context.strokePath()
        context.restoreGState()

        // Arrow.
        context.setLineWidth(1.9)
        context.move(to: tail)
        context.addLine(to: tip)
        context.move(to: CGPoint(x: tip.x - 4.3, y: tip.y))
        context.addLine(to: tip)
        context.addLine(to: CGPoint(x: tip.x, y: tip.y + 4.3))
        context.strokePath()
    }
}
