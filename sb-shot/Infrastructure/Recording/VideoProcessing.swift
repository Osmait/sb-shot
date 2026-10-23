import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoProcessingError: Error {
    case cannotCreateFile
    case exportFailed
}

/// Convierte un video a GIF animado con `AVAssetImageGenerator` + ImageIO. Se ejecuta fuera del hilo principal.
nonisolated enum GifExporter {
    /// ImageIO conserva todos los cuadros en memoria hasta finalizar, asi que se limita su numero.
    private static let maxFrames = 600
    static func export(
        videoURL: URL,
        to outputURL: URL,
        framesPerSecond: Int,
        maxWidth: CGFloat,
        timeRange: CMTimeRange? = nil,
        background: VideoBackgroundStyle? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: duration)

        // En clips largos se bajan los fps y el ancho para mantener la memoria y el tamano del GIF acotados.
        let requestedFrames = range.duration.seconds * Double(max(framesPerSecond, 1))
        let fps = requestedFrames > Double(maxFrames)
            ? max(Int(Double(maxFrames) / max(range.duration.seconds, 1)), 2)
            : max(framesPerSecond, 1)
        let width = requestedFrames > Double(maxFrames) ? min(maxWidth, 720) : maxWidth
        let frameCount = min(max(Int(range.duration.seconds * Double(fps)), 1), maxFrames)
        let times = (0 ..< frameCount).map {
            CMTimeAdd(range.start, CMTime(seconds: Double($0) / Double(fps), preferredTimescale: 600))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / Double(fps), preferredTimescale: 600)
        generator.maximumSize = CGSize(width: width, height: 10000)
        if let background {
            generator.videoComposition = try await VideoBackgroundCompositor.makeComposition(for: asset, style: background)
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw VideoProcessingError.cannotCreateFile
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)

        let delay = 1.0 / Double(fps)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        var added = 0
        var lastImage: CGImage?
        for await result in generator.images(for: times) {
            // Si un frame falla se repite el anterior para no desfasar la animacion.
            guard let image = (try? result.image) ?? lastImage else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
            lastImage = image
            added += 1
        }

        while added < frameCount, let lastImage {
            CGImageDestinationAddImage(destination, lastImage, frameProperties)
            added += 1
        }

        guard added > 0, CGImageDestinationFinalize(destination) else {
            throw VideoProcessingError.exportFailed
        }
        return outputURL
    }
}

enum VideoExporter {
    /// Exporta un tramo del video a MP4, opcionalmente sin audio, con una altura maxima y unos fps distintos.
    nonisolated static func export(
        videoURL: URL,
        to outputURL: URL,
        timeRange: CMTimeRange?,
        removeAudio: Bool,
        maxHeight: CGFloat? = nil,
        framesPerSecond: Int? = nil,
        background: VideoBackgroundStyle? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let range = timeRange ?? CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        var videoTrack: AVMutableCompositionTrack?
        var naturalSize = CGSize.zero
        var sourceFPS: Float = 0
        var mediaTypes: [AVMediaType] = [.video]
        if !removeAudio {
            mediaTypes.append(.audio)
        }

        for mediaType in mediaTypes {
            for track in try await asset.loadTracks(withMediaType: mediaType) {
                // Las pistas de audio pueden empezar despues o terminar antes que el video.
                let trackRange = try await track.load(.timeRange).intersection(range)
                guard trackRange.duration > .zero else { continue }

                let compositionTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionTrack?.insertTimeRange(trackRange, of: track, at: CMTimeSubtract(trackRange.start, range.start))
                if mediaType == .video {
                    compositionTrack?.preferredTransform = try await track.load(.preferredTransform)
                    if videoTrack == nil {
                        videoTrack = compositionTrack
                        naturalSize = try await track.load(.naturalSize)
                        sourceFPS = try await track.load(.nominalFrameRate)
                    }
                }
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoProcessingError.exportFailed
        }

        let changesFPS = framesPerSecond.map { Float($0) < sourceFPS - 0.5 } ?? false

        if let background {
            // La altura maxima se aplica al lienzo completo (video + fondo).
            let fullSize = VideoBackgroundCompositor.layout(videoSize: naturalSize, style: background).renderSize
            let scale = maxHeight.map { min($0 / max(fullSize.height, 1), 1) } ?? 1
            session.videoComposition = try await VideoBackgroundCompositor.makeComposition(
                for: composition,
                style: background,
                outputScale: scale,
                framesPerSecond: changesFPS ? framesPerSecond : nil
            )
        }

        let scale = maxHeight.map { min($0 / max(naturalSize.height, 1), 1) } ?? 1
        if background == nil, let videoTrack, scale < 1 || changesFPS {
            session.videoComposition = makeVideoComposition(
                track: videoTrack,
                duration: composition.duration,
                renderSize: CGSize(
                    width: CGFloat(Int(naturalSize.width * scale) / 2 * 2),
                    height: CGFloat(Int(naturalSize.height * scale) / 2 * 2)
                ),
                scale: scale,
                framesPerSecond: framesPerSecond ?? Int(sourceFPS.rounded())
            )
        }

        try? FileManager.default.removeItem(at: outputURL)
        try await session.export(to: outputURL, as: .mp4)
        return outputURL
    }

    private nonisolated static func makeVideoComposition(
        track: AVMutableCompositionTrack,
        duration: CMTime,
        renderSize: CGSize,
        scale: CGFloat,
        framesPerSecond: Int
    ) -> AVMutableVideoComposition {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(CGAffineTransform(scaleX: scale, y: scale), at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(framesPerSecond, 1)))
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    /// Fotogramas repartidos a lo largo del video, para la barra de recorte.
    static func filmstrip(for videoURL: URL, count: Int, height: CGFloat) async -> [NSImage] {
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let times = (0 ..< count).map {
            CMTime(seconds: duration.seconds * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)
        }

        var images: [NSImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                images.append(NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
            }
        }
        return images
    }

    static func thumbnail(for videoURL: URL, maxSize: CGSize = CGSize(width: 800, height: 800)) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize

        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else {
            return nil
        }
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }

    static func duration(of videoURL: URL) async -> TimeInterval {
        let duration = try? await AVURLAsset(url: videoURL).load(.duration)
        return duration?.seconds ?? 0
    }
}
