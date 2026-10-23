import AppKit
import ScreenCaptureKit

/// Conversion entre coordenadas globales de AppKit (origen abajo-izquierda) y de CoreGraphics (origen arriba-izquierda).
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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = ownWindows(in: content)
        var snapshots: [CGDirectDisplayID: CGImage] = [:]

        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = configuration(for: filter, size: display.frame.size, scale: CGFloat(filter.pointPixelScale))
            snapshots[display.displayID] = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
        return snapshots
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
            // Si el area queda parcialmente fuera de las pantallas, el resultado es solo la parte visible.
            return NSImage(cgImage: chunk.image, size: chunk.destination.size)
        }
        return try compose(chunks, size: selection.size, scale: outputScale)
    }

    private func captureWindow(_ window: SCWindow, options: CaptureOptions) async throws -> NSImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = options.downscaleToOneX ? 1 : CGFloat(filter.pointPixelScale)
        let config = configuration(for: filter, size: filter.contentRect.size, scale: scale)
        config.ignoreShadowsSingleWindow = !options.includeWindowShadow
        config.shouldBeOpaque = false

        // Pendiente de verificar en vivo: con sombra el contenido puede ser mas grande que el frame de la ventana
        // (ver RecordingIntegrationTests.capturesWindowWithAndWithoutShadow).
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return NSImage(cgImage: image, size: size)
    }

    private func configuration(for _: SCContentFilter, size: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(Int((size.width * scale).rounded()), 1)
        config.height = max(Int((size.height * scale).rounded()), 1)
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    private func compose(_ chunks: [(image: CGImage, destination: CGRect)], size: CGSize, scale: CGFloat) throws -> NSImage {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())

        guard
            let first = chunks.first?.image,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace.renderable(for: first),
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
        return NSImage(cgImage: output, size: size)
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
