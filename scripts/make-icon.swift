// Draws the app icon (an annotated window on a graphite tile) into
// sb-shot/Assets.xcassets/AppIcon.appiconset at every size macOS needs.
//
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("sb-shot/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon on a `pixels`-wide canvas. The artwork is laid out on a 400-unit
/// tile, which fills 824 of every 1024 pixels like Apple's macOS icon grid.
func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Top-left origin, so coordinates match the design.
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)

    let unit = size * 824 / 1024 / 400
    let origin = size * 100 / 1024
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: origin + x * unit, y: origin + y * unit, width: w * unit, height: h * unit)
    }
    func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius * unit, cornerHeight: radius * unit, transform: nil)
    }

    let tile = rounded(rect(0, 0, 400, 400), 90)

    // Drop shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10 * unit), blur: 24 * unit, color: color(0x000000, 0.35))
    context.addPath(tile)
    context.setFillColor(color(0x15181F))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()

    // Graphite gradient, lighter at the top left.
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x7B8496), color(0x3F4656), color(0x15181F)] as CFArray,
                              locations: [0, 0.5, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: origin + 100 * unit, y: origin - 20 * unit),
                               end: CGPoint(x: origin + 300 * unit, y: origin + 420 * unit), options: [])

    // The window being annotated.
    let card = rect(84, 96, 232, 176)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10 * unit), blur: 28 * unit, color: color(0x000000, 0.3))
    context.addPath(rounded(card, 26))
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    for (index, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        context.addEllipse(in: rect(84 + 22 + CGFloat(index) * 24, 96 + 20, 16, 16))
        context.setFillColor(color(UInt32(hex)))
        context.fillPath()
    }
    for (top, width) in [(62.0, 120.0), (92.0, 80.0)] as [(CGFloat, CGFloat)] {
        context.addPath(rounded(rect(84 + 24, 96 + top, width, 16), 8))
        context.setFillColor(color(0xE4E1EE))
        context.fillPath()
    }

    // Highlight box, inset by half its border so the stroke sits inside the frame.
    context.addPath(rounded(rect(84 + 112 + 4, 96 + 82 + 4, 88, 62), 10))
    context.setStrokeColor(color(0xFF9F1C))
    context.setLineWidth(8 * unit)
    context.strokePath()

    // Numbered marker.
    context.addEllipse(in: rect(272, 66, 64, 64))
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.addEllipse(in: rect(279, 73, 50, 50))
    context.setFillColor(color(0x1E7BFF))
    context.fillPath()
    let digit = NSAttributedString(string: "1", attributes: [
        .font: NSFont.systemFont(ofSize: 30 * unit, weight: .bold),
        .foregroundColor: NSColor.white,
    ])
    let line = CTLineCreateWithAttributedString(digit)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.saveGState()
    // Text draws with a bottom-left origin; flip back around the marker's center.
    let center = CGPoint(x: origin + 304 * unit, y: origin + 98 * unit)
    context.translateBy(x: center.x, y: center.y)
    context.scaleBy(x: 1, y: -1)
    context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
    CTLineDraw(line, context)
    context.restoreGState()

    // Arrow pointing up into the highlight.
    context.saveGState()
    context.translateBy(x: origin + 70 * unit, y: origin + 330 * unit)
    context.rotate(by: -34 * .pi / 180)
    context.setFillColor(color(0xF2453D))
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: -11 * unit, width: 140 * unit, height: 22 * unit),
                           cornerWidth: 11 * unit, cornerHeight: 11 * unit, transform: nil))
    context.fillPath()
    context.move(to: CGPoint(x: 132 * unit, y: -30 * unit))
    context.addLine(to: CGPoint(x: 184 * unit, y: 0))
    context.addLine(to: CGPoint(x: 132 * unit, y: 30 * unit))
    context.closePath()
    context.fillPath()
    context.restoreGState()

    // Hairline edge.
    context.addPath(rounded(rect(1, 1, 398, 398), 89))
    context.setStrokeColor(color(0xFFFFFF, 0.12))
    context.setLineWidth(2 * unit)
    context.strokePath()
    context.restoreGState()

    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(iconSet.path)")
