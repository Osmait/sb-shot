import AppKit
import Combine
import ScreenCaptureKit

/// Fondo de pantalla actual, para usarlo como fondo de capturas y videos.
/// Se captura la ventana del escritorio con ScreenCaptureKit, porque en sandbox no siempre se puede leer
/// el archivo (y asi tambien funcionan los fondos dinamicos). Si falla, se intenta leer el archivo del sistema.
/// La captura, la lectura y la miniatura se hacen fuera del hilo principal.
final class WallpaperProvider: ObservableObject {
    static let shared = WallpaperProvider()

    @Published private(set) var image: CGImage?
    @Published private(set) var thumbnail: CGImage?

    private var loadTask: Task<Loaded?, Never>?
    private var loadedAt: Date?
    private var loadedDisplayID: CGDirectDisplayID?

    /// Tiempo durante el que se reutiliza la ultima lectura sin volver a capturar.
    private static let maxAge: TimeInterval = 30

    private struct Loaded: Sendable {
        let image: CGImage
        let thumbnail: CGImage
    }

    /// Lee el fondo solo si no hay uno cargado, es de otra pantalla o tiene mas de `maxAge` segundos.
    /// Asi abrir un editor no vuelve a capturar ni invalida la cache del desenfoque.
    @discardableResult
    func refreshIfStale() async -> CGImage? {
        let displayID = ScreenGeometry.screenUnderCursor.flatMap(ScreenGeometry.displayID(of:))
        if let image, let loadedAt, loadedDisplayID == displayID, Date().timeIntervalSince(loadedAt) < Self.maxAge {
            return image
        }
        return await refresh()
    }

    /// Vuelve a leer el fondo de la pantalla bajo el cursor. Las llamadas simultaneas comparten la misma carga.
    @discardableResult
    func refresh() async -> CGImage? {
        if let loadTask {
            return await loadTask.value?.image ?? image
        }
        let screen = ScreenGeometry.screenUnderCursor
        let displayID = screen.flatMap(ScreenGeometry.displayID(of:))
        let fileURL = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let task = Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let image = await Self.capture(displayID: displayID) ?? Self.readFile(url: fileURL) else { return nil }
            return Loaded(image: image, thumbnail: Self.downsample(image, maxPixelDimension: 480) ?? image)
        }
        loadTask = task
        let loaded = await task.value
        loadTask = nil

        if let loaded {
            image = loaded.image
            thumbnail = loaded.thumbnail
            loadedAt = Date()
            loadedDisplayID = displayID
        }
        return image
    }

    // MARK: - Private

    private nonisolated static let maxPixelDimension: CGFloat = 3840

    private nonisolated static func capture(displayID: CGDirectDisplayID?) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
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

    private nonisolated static func readFile(url: URL?) -> CGImage? {
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    fileprivate nonisolated static func downsample(_ image: CGImage, maxPixelDimension: CGFloat) -> CGImage? {
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

/// Fondo de pantalla desenfocado y/o reducido. Guarda los ultimos resultados para no recalcularlos en cada
/// redibujado del lienzo. Se puede usar desde cualquier hilo.
nonisolated enum WallpaperBlur {
    /// Lado mayor de la imagen al desenfocar. Una imagen borrosa no necesita mas resolucion y asi el slider responde rapido.
    private static let referenceDimension: CGFloat = 1600
    /// Paso al redondear el tamano pedido, para no recalcular con cada cambio pequeno del lienzo.
    private static let dimensionStep: CGFloat = 256
    private static let cacheLimit = 4

    private struct Entry {
        let source: CGImage
        let radius: CGFloat
        /// Lado mayor del resultado pedido, o `nil` para la version sin limite.
        let dimension: CGFloat?
        let result: CGImage
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [Entry] = []

    static func image(_ wallpaper: CGImage, radius: CGFloat) -> CGImage {
        guard radius > 0 else { return wallpaper }
        return cached(wallpaper, radius: radius, dimension: nil)
    }

    /// Version para dibujar con relleno proporcional en un lienzo de `pixelSize` pixeles: no mayor de lo necesario.
    /// Con desenfoque se ve igual que `image(_:radius:)`, solo que a menor resolucion si el lienzo es pequeno.
    static func image(_ wallpaper: CGImage, radius: CGFloat, covering pixelSize: CGSize) -> CGImage {
        let source = CGSize(width: wallpaper.width, height: wallpaper.height)
        let fill = max(pixelSize.width / max(source.width, 1), pixelSize.height / max(source.height, 1))
        let needed = max(source.width, source.height) * fill
        let dimension = (max(needed, 1) / dimensionStep).rounded(.up) * dimensionStep

        if radius <= 0, dimension >= max(source.width, source.height) {
            return wallpaper
        }
        return cached(wallpaper, radius: max(radius, 0), dimension: dimension)
    }

    private static func cached(_ wallpaper: CGImage, radius: CGFloat, dimension: CGFloat?) -> CGImage {
        lock.lock()
        if let index = cache.firstIndex(where: { $0.source === wallpaper && $0.radius == radius && $0.dimension == dimension }) {
            let entry = cache.remove(at: index)
            cache.append(entry)
            lock.unlock()
            return entry.result
        }
        lock.unlock()

        let result = make(wallpaper, radius: radius, dimension: dimension) ?? wallpaper

        lock.lock()
        cache.append(Entry(source: wallpaper, radius: radius, dimension: dimension, result: result))
        if cache.count > cacheLimit {
            cache.removeFirst(cache.count - cacheLimit)
        }
        lock.unlock()
        return result
    }

    private static func make(_ wallpaper: CGImage, radius: CGFloat, dimension: CGFloat?) -> CGImage? {
        let largest = CGFloat(max(wallpaper.width, wallpaper.height, 1))

        guard radius > 0 else {
            return WallpaperProvider.downsample(wallpaper, maxPixelDimension: dimension ?? largest)
        }

        // El radio esta definido sobre la imagen de referencia; si se trabaja mas pequeno se escala igual.
        let referenceScale = min(referenceDimension / largest, 1)
        let workScale = min(referenceScale, (dimension ?? .infinity) / largest)
        let sigma = radius * workScale / referenceScale

        var input = CIImage(cgImage: wallpaper)
        input = input.transformed(by: CGAffineTransform(scaleX: workScale, y: workScale))
        let extent = input.extent.integral

        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
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
