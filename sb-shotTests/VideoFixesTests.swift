import AppKit
import AVFoundation
import CoreGraphics
@testable import SbShot
import Testing

// MARK: - WallpaperBlur

struct WallpaperBlurTests {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    @Test func zeroRadiusReturnsSameImage() {
        let image = makeImage(width: 200, height: 100)
        #expect(WallpaperBlur.image(image, radius: 0) === image)
    }

    @Test func zeroRadiusCoveringSmallerOrEqualCanvasReturnsSameImage() {
        // Canvas equal to or larger than the image: no need to downscale it.
        let image = makeImage(width: 200, height: 100)
        let result = WallpaperBlur.image(image, radius: 0, covering: CGSize(width: 200, height: 100))
        #expect(result === image)
    }

    @Test func blurResultIsCached() {
        let image = makeImage(width: 200, height: 100)
        let first = WallpaperBlur.image(image, radius: 5)
        let second = WallpaperBlur.image(image, radius: 5)
        #expect(first !== image)
        #expect(first === second)
    }

    @Test func coveringBlurResultIsCached() {
        let image = makeImage(width: 200, height: 100)
        let size = CGSize(width: 100, height: 50)
        let first = WallpaperBlur.image(image, radius: 4, covering: size)
        let second = WallpaperBlur.image(image, radius: 4, covering: size)
        #expect(first === second)
    }

    @Test func differentRadiusProducesDifferentResult() {
        let image = makeImage(width: 200, height: 100)
        let a = WallpaperBlur.image(image, radius: 3)
        let b = WallpaperBlur.image(image, radius: 9)
        #expect(a !== b)
    }

    @Test func coveringDownsizesToRoughlyRequestedSize() {
        // 2000x1000 covering 400x200 px: ~2000*0.2... = 400 px on the longer side are needed, rounded to 256 => 512.
        let image = makeImage(width: 2000, height: 1000)
        let size = CGSize(width: 400, height: 200)

        for radius: CGFloat in [0, 6] {
            let result = WallpaperBlur.image(image, radius: radius, covering: size)
            #expect(result.width < image.width)
            #expect(result.width >= 400)
            #expect(result.width <= 400 + 256)
            // Preserves the aspect ratio.
            let ratio = Double(result.width) / Double(result.height)
            #expect(abs(ratio - 2.0) < 0.05)
        }
    }

    @Test func coveringTallCanvasUsesLargerDimension() {
        // 2000x1000 image on a 300x600 canvas: covering requires scale 0.6 => longer side 1200 => 1280.
        let image = makeImage(width: 2000, height: 1000)
        let result = WallpaperBlur.image(image, radius: 0, covering: CGSize(width: 300, height: 600))
        #expect(result.width >= 1200)
        #expect(result.width <= 1280)
    }
}

// MARK: - GIF frame sampling

struct GifSamplingTests {
    private func times(duration: Double, fps: Int) -> [Double] {
        let sampling = GifExporter.frameSampling(duration: duration, framesPerSecond: fps)
        return (0 ..< sampling.frameCount).map { Double($0) * sampling.step }
    }

    @Test func longClipCoversWholeRangeWithinFrameCap() {
        let sampling = GifExporter.frameSampling(duration: 400, framesPerSecond: 15)
        #expect(sampling.isLong)
        #expect(sampling.frameCount <= 600)

        let all = times(duration: 400, fps: 15)
        let last = all.last ?? 0
        #expect(last > 395) // used to stall at ~300 s
        #expect(last < 400)
        #expect(all.first == 0)
        // Uniform step.
        #expect(abs(sampling.step - 400.0 / 600.0) < 1e-9)
    }

    @Test func clipJustOverCapStillCoversRange() {
        // 41 s at 15 fps = 615 frames requested > 600.
        let sampling = GifExporter.frameSampling(duration: 41, framesPerSecond: 15)
        #expect(sampling.isLong)
        #expect(sampling.frameCount == 600)
        #expect((times(duration: 41, fps: 15).last ?? 0) > 40)
    }

    @Test func shortClipKeepsRequestedFps() {
        let sampling = GifExporter.frameSampling(duration: 10, framesPerSecond: 15)
        #expect(sampling.isLong == false)
        #expect(sampling.frameCount == 150)
        #expect(abs(sampling.step - 1.0 / 15.0) < 1e-9)
    }

    @Test func exactlyAtCapIsNotLong() {
        let sampling = GifExporter.frameSampling(duration: 40, framesPerSecond: 15)
        #expect(sampling.isLong == false)
        #expect(sampling.frameCount == 600)
    }

    @Test func tinyClipHasAtLeastOneFrame() {
        let sampling = GifExporter.frameSampling(duration: 0.01, framesPerSecond: 10)
        #expect(sampling.frameCount == 1)
    }

    @Test func zeroFpsIsTreatedAsOne() {
        let sampling = GifExporter.frameSampling(duration: 5, framesPerSecond: 0)
        #expect(sampling.frameCount == 5)
        #expect(sampling.step == 1)
    }
}

// MARK: - Trim clamping

@MainActor
struct VideoTrimTests {
    private func makeVideo(seconds: Double, in folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("clip.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = 10
        let count = Int(seconds * Double(fps))
        for frame in 0 ... count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? VideoProcessingError.exportFailed }
        return url
    }

    private func makeModel(seconds: Double) async throws -> (VideoEditorModel, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trim-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = try await makeVideo(seconds: seconds, in: folder)
        let model = VideoEditorModel(
            videoURL: url,
            actions: VideoEditorActions(onCopy: { _ in }, onSave: { _ in }, defaultFormat: .mp4, gifFramesPerSecond: 15)
        )
        for _ in 0 ..< 200 where model.duration == 0 {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        return (model, folder)
    }

    @Test func trimIsIgnoredBeforeDurationLoads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trim-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try await makeVideo(seconds: 1, in: folder)
        let model = VideoEditorModel(
            videoURL: url,
            actions: VideoEditorActions(onCopy: { _ in }, onSave: { _ in }, defaultFormat: .mp4, gifFramesPerSecond: 15)
        )
        defer { model.tearDown() }

        // Right after creating the model the duration is still 0 (it loads asynchronously).
        guard model.duration == 0 else { return }
        model.setTrimStart(0.5)
        model.setTrimEnd(0.9)
        #expect(model.trimStart == 0)
        #expect(model.trimEnd == 0)
    }

    @Test func trimValuesAreClampedAndKeepMinimumLength() async throws {
        let (model, folder) = try await makeModel(seconds: 2)
        defer { model.tearDown(); try? FileManager.default.removeItem(at: folder) }
        let duration = model.duration
        try #require(duration >= 1.5)
        #expect(model.trimStart == 0)
        #expect(model.trimEnd == duration)

        // Negative start: clamped to 0.
        model.setTrimStart(-5)
        #expect(model.trimStart == 0)

        // Start past the end: stays `minimumLength` before the end.
        model.setTrimStart(duration + 10)
        #expect(abs(model.trimStart - (duration - VideoEditorModel.minimumLength)) < 1e-9)
        #expect(model.trimStart < model.trimEnd)

        // End past the duration: clamped to the duration.
        model.setTrimEnd(duration + 10)
        #expect(model.trimEnd == duration)

        // End before the start: stays `minimumLength` after the start.
        model.setTrimEnd(0)
        #expect(abs(model.trimEnd - (model.trimStart + VideoEditorModel.minimumLength)) < 1e-9)
        #expect(model.trimStart < model.trimEnd)

        // Normal values.
        model.resetTrim()
        model.setTrimStart(0.5)
        model.setTrimEnd(1.5)
        #expect(model.trimStart == 0.5)
        #expect(model.trimEnd == 1.5)
        #expect(model.trimLength == 1.0)
    }

    @Test func trimNeverLeavesRange() async throws {
        let (model, folder) = try await makeModel(seconds: 1)
        defer { model.tearDown(); try? FileManager.default.removeItem(at: folder) }
        let duration = model.duration
        try #require(duration >= VideoEditorModel.minimumLength)

        for value in [-100.0, -1, 0, 0.1, 0.5, duration, duration + 1, 1000] {
            model.setTrimStart(value)
            model.setTrimEnd(value)
            #expect(model.trimStart >= 0)
            #expect(model.trimEnd <= duration)
            #expect(model.trimStart < model.trimEnd)
        }
    }
}
