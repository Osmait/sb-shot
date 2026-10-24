import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoProcessingError: Error {
    case cannotCreateFile
    case exportFailed
}

/// Converts a video to an animated GIF with `AVAssetImageGenerator` + ImageIO. Runs off the main thread.
nonisolated enum GifExporter {
    /// ImageIO keeps every frame in memory until finalizing, so their number is capped.
    private static let maxFrames = 600

    /// Frame count and step (in seconds) for a range: long ranges spread `maxFrames` across the whole range.
    static func frameSampling(duration seconds: Double, framesPerSecond: Int) -> (frameCount: Int, step: Double, isLong: Bool) {
        let requestedFrames = seconds * Double(max(framesPerSecond, 1))
        let isLong = requestedFrames > Double(maxFrames)
        let frameCount = isLong ? maxFrames : max(Int(requestedFrames), 1)
        let step = isLong ? seconds / Double(maxFrames) : 1.0 / Double(max(framesPerSecond, 1))
        return (frameCount, step, isLong)
    }
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

        // Long clips spread `maxFrames` frames across the whole range (fractional step) and lower the width
        // to keep memory and GIF size bounded without cutting off the end.
        let seconds = range.duration.seconds
        let sampling = frameSampling(duration: seconds, framesPerSecond: framesPerSecond)
        let frameCount = sampling.frameCount
        let step = sampling.step
        let width = sampling.isLong ? min(maxWidth, 720) : maxWidth
        let times = (0 ..< frameCount).map {
            CMTimeAdd(range.start, CMTime(seconds: Double($0) * step, preferredTimescale: 600))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: step / 2, preferredTimescale: 600)
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

        let delay = step
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        var added = 0
        var lastImage: CGImage?
        for await result in generator.images(for: times) {
            if Task.isCancelled { break }
            // If a frame fails, repeat the previous one so the animation stays in sync.
            guard let image = (try? result.image) ?? lastImage else { continue }
            CGImageDestinationAddImage(destination, image, frameProperties)
            lastImage = image
            added += 1
        }
        try Task.checkCancellation()

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
    /// Exports a range of the video to MP4, optionally without audio, with a maximum height and a different frame rate.
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
                // Audio tracks may start later or end earlier than the video.
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
            // The maximum height applies to the whole canvas (video + background).
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

    /// Frames spread across the video, for the trim bar.
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
