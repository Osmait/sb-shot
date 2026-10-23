import AppKit
import CoreImage

/// Imagen base y sus variantes (pixelada, desenfocada) que usa el renderer. Las variantes se calculan una sola vez.
final class RenderSources {
    let base: CGImage
    /// Tamano en puntos de la imagen original. Las anotaciones se guardan en este espacio.
    let pointSize: CGSize

    private var pixelatedCache: CGImage?
    private var blurredCache: CGImage?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init?(image: NSImage, maxPixelDimension: CGFloat? = nil) {
        guard var cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        if let maxPixelDimension, let downsampled = Self.downsample(cgImage, maxPixelDimension: maxPixelDimension) {
            cgImage = downsampled
        }

        base = cgImage
        pointSize = image.size
    }

    var pixelScale: CGFloat {
        CGFloat(base.width) / max(pointSize.width, 1)
    }

    var pixelated: CGImage? {
        if let pixelatedCache {
            return pixelatedCache
        }
        let input = CIImage(cgImage: base)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        filter?.setValue(12 * pixelScale, forKey: kCIInputScaleKey)
        pixelatedCache = filter?.outputImage.flatMap { Self.ciContext.createCGImage($0, from: input.extent) }
        return pixelatedCache
    }

    var blurred: CGImage? {
        if let blurredCache {
            return blurredCache
        }
        let input = CIImage(cgImage: base)
        let filter = CIFilter(name: "CIGaussianBlur")
        filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter?.setValue(14 * pixelScale, forKey: kCIInputRadiusKey)
        blurredCache = filter?.outputImage.flatMap { Self.ciContext.createCGImage($0, from: input.extent) }
        return blurredCache
    }

    func image(for mode: ObfuscationMode) -> CGImage? {
        switch mode {
        case .pixelate: pixelated
        case .blur: blurred
        }
    }

    private static func downsample(_ image: CGImage, maxPixelDimension: CGFloat) -> CGImage? {
        let largest = CGFloat(max(image.width, image.height))
        guard largest > maxPixelDimension else { return nil }

        let ratio = maxPixelDimension / largest
        let width = Int(CGFloat(image.width) * ratio)
        let height = Int(CGFloat(image.height) * ratio)
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
