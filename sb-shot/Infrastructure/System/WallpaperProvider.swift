import AppKit
import Combine
import ScreenCaptureKit

/// Fondo de pantalla actual, para usarlo como fondo de capturas y videos.
/// Se captura la ventana del escritorio con ScreenCaptureKit, porque en sandbox no siempre se puede leer
/// el archivo (y asi tambien funcionan los fondos dinamicos). Si falla, se intenta leer el archivo del sistema.
final class WallpaperProvider: ObservableObject {
    static let shared = WallpaperProvider()

    @Published private(set) var image: CGImage?
    @Published private(set) var thumbnail: CGImage?

    private var loadTask: Task<CGImage?, Never>?

    /// Vuelve a leer el fondo de la pantalla bajo el cursor. Las llamadas simultaneas comparten la misma carga.
    @discardableResult
    func refresh() async -> CGImage? {
        if let loadTask {
            return await loadTask.value
        }
        let screen = ScreenGeometry.screenUnderCursor
        let task = Task { await Self.capture(screen: screen) ?? Self.readFile(screen: screen) }
        loadTask = task
        let loaded = await task.value
        loadTask = nil

        if let loaded {
            image = loaded
            thumbnail = Self.downsample(loaded, maxPixelDimension: 480) ?? loaded
        }
        return image
    }

    // MARK: - Private

    private static let maxPixelDimension: CGFloat = 3840

    private static func capture(screen: NSScreen?) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let displayID = screen.flatMap(ScreenGeometry.displayID(of:))
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { return nil }

        // El Dock dibuja el fondo en ventanas "Wallpaper-<id>", una por pantalla.
        let wallpapers = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == "com.apple.dock"
                && (window.title ?? "").hasPrefix("Wallpaper")
                && window.frame.intersects(display.frame)
        }
        guard !wallpapers.isEmpty else { return nil }

        let filter = SCContentFilter(display: display, including: wallpapers)
        let scale = min(CGFloat(filter.pointPixelScale), maxPixelDimension / max(display.frame.width, display.frame.height, 1))
        let config = SCStreamConfiguration()
        config.width = Int(display.frame.width * scale)
        config.height = Int(display.frame.height * scale)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func readFile(screen: NSScreen?) -> CGImage? {
        guard
            let screen,
            let url = NSWorkspace.shared.desktopImageURL(for: screen),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func downsample(_ image: CGImage, maxPixelDimension: CGFloat) -> CGImage? {
        let ratio = min(maxPixelDimension / CGFloat(max(image.width, image.height)), 1)
        let width = max(Int(CGFloat(image.width) * ratio), 1)
        let height = max(Int(CGFloat(image.height) * ratio), 1)
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace.renderable(for: image),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Fondo de pantalla desenfocado. Guarda el ultimo resultado para no recalcularlo en cada redibujado del lienzo.
enum WallpaperBlur {
    /// Lado mayor de la imagen al desenfocar. Una imagen borrosa no necesita mas resolucion y asi el slider responde rapido.
    private static let referenceDimension: CGFloat = 1600

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static var cache: (source: CGImage, radius: CGFloat, result: CGImage)?

    static func image(_ wallpaper: CGImage, radius: CGFloat) -> CGImage {
        guard radius > 0 else { return wallpaper }
        if let cache, cache.source === wallpaper, cache.radius == radius {
            return cache.result
        }

        var input = CIImage(cgImage: wallpaper)
        let scale = min(referenceDimension / max(input.extent.width, input.extent.height, 1), 1)
        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = input.extent.integral

        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: extent)
        guard let result = ciContext.createCGImage(blurred, from: extent) else { return wallpaper }

        cache = (wallpaper, radius, result)
        return result
    }
}

nonisolated extension CGRect {
    /// Rectangulo que cubre `bounds` por completo manteniendo la proporcion de `size`, centrado.
    static func aspectFill(_ size: CGSize, in bounds: CGRect) -> CGRect {
        let scale = max(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
