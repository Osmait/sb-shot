import AppKit
import ScreenCaptureKit

/// Conversion between AppKit global coordinates (bottom-left origin) and CoreGraphics ones (top-left origin).
enum ScreenGeometry {
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func toCoreGraphics(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }

    static var screenUnderCursor: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}

struct ScreenCaptureService {
    enum CaptureError: Error {
        case emptyResult
        case displayNotFound
        case windowNotFound
    }

    func displaySnapshots() async throws -> [CGDirectDisplayID: CGImage] {
        try await displaySnapshots(hidingDesktopIcons: false)
    }

    func displaySnapshots(hidingDesktopIcons: Bool) async throws -> [CGDirectDisplayID: CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = excludedWindows(in: content, hideDesktopIcons: hidingDesktopIcons)
        let requests = content.displays.map { display in
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = configuration(for: filter, size: display.frame.size, scale: CGFloat(filter.pointPixelScale))
            return (id: display.displayID, filter: filter, config: config)
        }

        // Displays are captured concurrently: serially, with several Retina displays, the overlay is slow to appear.
        return try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group in
            for request in requests {
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: request.filter, configuration: request.config)
                    return (request.id, image)
                }
            }
            var snapshots: [CGDirectDisplayID: CGImage] = [:]
            for try await (id, image) in group {
                snapshots[id] = image
            }
            return snapshots
        }
    }

    func capture(_ selection: ScreenSelection, options: CaptureOptions) async throws -> NSImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        switch selection {
        case let .area(rect):
            return try await captureArea(rect, content: content, options: options)

        case let .display(id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.displayNotFound
            }
            return try await captureArea(ScreenGeometry.toAppKit(display.frame), content: content, options: options)

        case let .window(id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.windowNotFound
            }
            return try await captureWindow(window, options: options)
        }
    }

    // MARK: - Private

    private func captureArea(_ globalRect: CGRect, content: SCShareableContent, options: CaptureOptions) async throws -> NSImage {
        let selection = ScreenGeometry.toCoreGraphics(globalRect.standardized.integral)
        guard selection.width > 1, selection.height > 1 else { throw CaptureError.emptyResult }

        let excluded = excludedWindows(in: content, hideDesktopIcons: options.hideDesktopIcons)
        var chunks: [(image: CGImage, destination: CGRect)] = []
        var outputScale: CGFloat = 1

        for display in content.displays {
            let overlap = selection.intersection(display.frame)
            if overlap.isNull || overlap.isEmpty {
                continue
            }

            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let scale = options.downscaleToOneX ? 1 : CGFloat(filter.pointPixelScale)
            outputScale = max(outputScale, scale)

            let config = configuration(for: filter, size: overlap.size, scale: scale)
            config.sourceRect = CGRect(
                x: overlap.minX - display.frame.minX,
                y: overlap.minY - display.frame.minY,
                width: overlap.width,
                height: overlap.height
            )

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let destination = CGRect(
                x: overlap.minX - selection.minX,
                y: overlap.minY - selection.minY,
                width: overlap.width,
                height: overlap.height
            )
            chunks.append((image, destination))
        }

        guard !chunks.isEmpty else { throw CaptureError.emptyResult }

        if chunks.count == 1, let chunk = chunks.first {
            // If the area is partially off-screen, the result is only the visible part.
            return NSImage(cgImage: chunk.image, size: chunk.destination.size)
        }
        let composed = try await Self.compose(chunks, size: selection.size, scale: outputScale)
        return NSImage(cgImage: composed, size: selection.size)
    }

    private func captureWindow(_ window: SCWindow, options: CaptureOptions) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = options.downscaleToOneX ? 1 : CGFloat(filter.pointPixelScale)

        // The shadow extends beyond the window. If the canvas is the same size as the window, ScreenCaptureKit shrinks
        // the window to fit the shadow; so it is captured unscaled on a canvas with a margin and the transparent
        // edges are trimmed afterwards.
        let margin: CGFloat = options.includeWindowShadow ? Self.shadowMargin : 0
        let canvas = CGSize(width: filter.contentRect.width + margin * 2, height: filter.contentRect.height + margin * 2)
        let config = configuration(for: filter, size: canvas, scale: scale)
        config.ignoreShadowsSingleWindow = !options.includeWindowShadow
        config.shouldBeOpaque = false
        config.scalesToFit = false

        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if margin > 0, let trimmed = await Self.trimmingTransparentEdges(image) {
            image = trimmed
        }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return NSImage(cgImage: image, size: size)
    }

    private static let shadowMargin: CGFloat = 100

    /// Trims the fully transparent rows and columns around the image. Runs off the main thread
    /// and only draws the alpha channel (one byte per pixel).
    @concurrent
    nonisolated static func trimmingTransparentEdges(_ image: CGImage) async -> CGImage? {
        let width = image.width
        let height = image.height
        guard
            width > 0, height > 0,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        let alpha = data.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = context.bytesPerRow

        func rowHasContent(_ y: Int) -> Bool {
            let row = alpha + y * bytesPerRow
            for x in 0 ..< width where row[x] > 2 {
                return true
            }
            return false
        }
        func columnHasContent(_ x: Int, rows: ClosedRange<Int>) -> Bool {
            for y in rows where alpha[y * bytesPerRow + x] > 2 {
                return true
            }
            return false
        }

        // The buffer has the first row at the top, same as `cropping(to:)`.
        guard let top = (0 ..< height).first(where: rowHasContent),
              let bottom = (0 ..< height).reversed().first(where: rowHasContent)
        else { return nil }
        let rows = top ... bottom
        guard let left = (0 ..< width).first(where: { columnHasContent($0, rows: rows) }),
              let right = (0 ..< width).reversed().first(where: { columnHasContent($0, rows: rows) })
        else { return nil }

        return image.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1))
    }

    private func configuration(for _: SCContentFilter, size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(Int((size.width * scale).rounded()), 1)
        config.height = max(Int((size.height * scale).rounded()), 1)
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    /// Joins the chunks from several displays off the main thread.
    @concurrent
    nonisolated static func compose(
        _ chunks: [(image: CGImage, destination: CGRect)],
        size: CGSize,
        scale: CGFloat
    ) async throws -> CGImage {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())

        // Same as `CGColorSpace.renderable(for:)`, which is isolated to the main thread.
        let firstSpace = chunks.first?.image.colorSpace
        let space = firstSpace?.model == .rgb ? firstSpace : CGColorSpace(name: CGColorSpace.sRGB)

        guard
            let space,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CaptureError.emptyResult }

        context.interpolationQuality = .high
        for chunk in chunks {
            let rect = CGRect(
                x: chunk.destination.minX * scale,
                y: (size.height - chunk.destination.maxY) * scale,
                width: chunk.destination.width * scale,
                height: chunk.destination.height * scale
            )
            context.draw(chunk.image, in: rect)
        }

        guard let output = context.makeImage() else { throw CaptureError.emptyResult }
        return output
    }

    private func ownWindows(in content: SCShareableContent) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter { $0.owningApplication?.processID == pid }
    }

    private func excludedWindows(in content: SCShareableContent, hideDesktopIcons: Bool) -> [SCWindow] {
        var excluded = ownWindows(in: content)
        if hideDesktopIcons {
            let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
            excluded += content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.finder" && $0.windowLayer == iconLevel
            }
        }
        return excluded
    }
}

extension ScreenCaptureService: ScreenCaptureProviding {}
