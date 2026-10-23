import AVFoundation
import CoreImage

/// Fondo para videos: el video queda centrado sobre un degradado o una imagen, con margen, esquinas redondeadas y sombra.
nonisolated struct VideoBackgroundStyle: Sendable {
    var startColor: CGColor
    var endColor: CGColor
    /// Imagen de fondo (el fondo de pantalla). Si existe, reemplaza al degradado.
    var image: CGImage?
    /// Margen y radio en puntos de un video de referencia de 1600 px; se escalan con el tamano real.
    var padding: CGFloat
    var cornerRadius: CGFloat
    var shadow: Bool
    /// Ancho / alto del lienzo, o `nil` para ajustarse al video.
    var aspectRatio: CGFloat?
}

nonisolated enum VideoBackgroundCompositor {
    struct Layout {
        /// Tamano del lienzo final en pixeles (par, para H.264).
        let renderSize: CGSize
        /// Donde se dibuja el video, en coordenadas de Core Image (origen abajo-izquierda).
        let contentRect: CGRect
        let unit: CGFloat
    }

    static func layout(videoSize: CGSize, style: VideoBackgroundStyle, outputScale: CGFloat = 1) -> Layout {
        let unit = max(max(videoSize.width, videoSize.height) / 1600, 1) * outputScale
        let padding = style.padding * unit
        let content = CGSize(width: videoSize.width * outputScale, height: videoSize.height * outputScale)

        var size = CGSize(width: content.width + padding * 2, height: content.height + padding * 2)
        if let ratio = style.aspectRatio {
            if size.width / max(size.height, 1) < ratio {
                size.width = size.height * ratio
            } else {
                size.height = size.width / ratio
            }
        }
        size = CGSize(width: CGFloat(Int(size.width) / 2 * 2), height: CGFloat(Int(size.height) / 2 * 2))

        let origin = CGPoint(x: ((size.width - content.width) / 2).rounded(), y: ((size.height - content.height) / 2).rounded())
        return Layout(renderSize: size, contentRect: CGRect(origin: origin, size: content), unit: unit)
    }

    /// Composicion que aplica el fondo a cada fotograma. Sirve para la reproduccion, la exportacion MP4 y el GIF.
    static func makeComposition(
        for asset: AVAsset,
        style: VideoBackgroundStyle,
        outputScale: CGFloat = 1,
        framesPerSecond: Int? = nil
    ) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProcessingError.exportFailed
        }
        let videoSize = try await track.load(.naturalSize)
        let layout = layout(videoSize: videoSize, style: style, outputScale: outputScale)
        let background = backgroundImage(layout: layout, style: style)
        let mask = roundedRect(layout.contentRect, radius: style.cornerRadius * layout.unit, color: .white)
        let transform = CGAffineTransform(a: outputScale, b: 0, c: 0, d: outputScale, tx: layout.contentRect.minX, ty: layout.contentRect.minY)
        let extent = CGRect(origin: .zero, size: layout.renderSize)

        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = request.sourceImage.transformed(by: transform)
            let output = frame.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: background,
                kCIInputMaskImageKey: mask,
            ])
            request.finish(with: output.cropped(to: extent), context: nil)
        }
        composition.renderSize = layout.renderSize
        if let framesPerSecond {
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1)))
        }
        return composition
    }

    // MARK: - Private

    private static func backgroundImage(layout: Layout, style: VideoBackgroundStyle) -> CIImage {
        let extent = CGRect(origin: .zero, size: layout.renderSize)
        let fill = style.image.map { imageFill($0, extent: extent) } ?? gradientFill(style, extent: extent)

        guard style.shadow else { return fill }

        let shadowRect = layout.contentRect.offsetBy(dx: 0, dy: -12 * layout.unit)
        let shadow = roundedRect(shadowRect, radius: style.cornerRadius * layout.unit, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 18 * layout.unit)
            .cropped(to: extent)
        return shadow.composited(over: fill)
    }

    private static func imageFill(_ image: CGImage, extent: CGRect) -> CIImage {
        let source = CIImage(cgImage: image)
        let rect = CGRect.aspectFill(source.extent.size, in: extent)
        let scale = rect.width / max(source.extent.width, 1)
        return source
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
            .cropped(to: extent)
    }

    private static func gradientFill(_ style: VideoBackgroundStyle, extent: CGRect) -> CIImage {
        CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: extent.height),
            "inputPoint1": CIVector(x: extent.width, y: 0),
            "inputColor0": CIColor(cgColor: style.startColor),
            "inputColor1": CIColor(cgColor: style.endColor),
        ])?.outputImage?.cropped(to: extent) ?? CIImage(color: .black).cropped(to: extent)
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let filter = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": min(radius, min(rect.width, rect.height) / 2),
            "inputColor": color,
        ])
        return filter?.outputImage ?? CIImage(color: color).cropped(to: rect)
    }
}
