import AppKit
import Combine
import ScreenCaptureKit

/// Current wallpaper, used as the background for screenshots and videos.
/// The desktop window is captured with ScreenCaptureKit, because the sandbox can't always read
/// the file (and this way dynamic wallpapers work too). If that fails, the system file is read instead.
/// Capturing, reading, and thumbnailing happen off the main thread.
final class WallpaperProvider: ObservableObject {
    static let shared = WallpaperProvider()

    @Published private(set) var image: CGImage?
    @Published private(set) var thumbnail: CGImage?

    private var loadTask: Task<Loaded?, Never>?
    #if DEBUG
    /// Demo mode: synthetic image used instead of the real wallpaper, which is never read.
    var demoImage: CGImage?
    #endif
    private var loadedAt: Date?
    private var loadedDisplayID: CGDirectDisplayID?

    /// How long the last read is reused without capturing again.
    private static let maxAge: TimeInterval = 30

    private struct Loaded: Sendable {
        let image: CGImage
        let thumbnail: CGImage
    }

    /// Reads the wallpaper only if none is loaded, it belongs to another screen, or it is older than `maxAge` seconds.
    /// This way opening an editor doesn't capture again or invalidate the blur cache.
    @discardableResult
    func refreshIfStale() async -> CGImage? {
        let displayID = ScreenGeometry.screenUnderCursor.flatMap(ScreenGeometry.displayID(of:))
        if let image, let loadedAt, loadedDisplayID == displayID, Date().timeIntervalSince(loadedAt) < Self.maxAge {
            return image
        }
        return await refresh()
    }

    /// Rereads the wallpaper of the screen under the cursor. Concurrent calls share the same load.
    @discardableResult
    func refresh() async -> CGImage? {
        #if DEBUG
        if let demoImage {
            image = demoImage
            thumbnail = Self.downsample(demoImage, maxPixelDimension: 480) ?? demoImage
            return demoImage
        }
        #endif
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

        // The Dock draws the wallpaper in "Wallpaper-<id>" windows, one per screen.
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

/// Blurred and/or downscaled wallpaper. Caches the latest results so they aren't recomputed on every
/// canvas redraw. Safe to use from any thread.
nonisolated enum WallpaperBlur {
    /// Longest side of the image when blurring. A blurred image doesn't need more resolution, and this keeps the slider responsive.
    private static let referenceDimension: CGFloat = 1600
    /// Step used to round the requested size, to avoid recomputing on every small canvas change.
    private static let dimensionStep: CGFloat = 256
    private static let cacheLimit = 4

    private struct Entry {
        let source: CGImage
        let radius: CGFloat
        /// Longest side of the requested result, or `nil` for the unlimited version.
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

    /// Version for aspect-fill drawing on a canvas of `pixelSize` pixels: no larger than needed.
    /// With blur it looks the same as `image(_:radius:)`, just at a lower resolution if the canvas is small.
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

        // The radius is defined on the reference image; when working at a smaller size it is scaled accordingly.
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
    /// Centered rectangle that fully covers `bounds` while keeping the aspect ratio of `size`.
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
