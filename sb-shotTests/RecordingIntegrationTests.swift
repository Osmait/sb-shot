import AppKit
import AVFoundation
@testable import SbShot
import Testing

/// Real integration tests: they capture and record the main screen.
/// They require screen recording permission and an unlocked session, so they only run with:
///
///     TEST_RUNNER_SBSHOT_INTEGRATION=1 xcodebuild test -scheme SbShot -only-testing:SbShotTests/RecordingIntegrationTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SBSHOT_INTEGRATION"] != nil))
struct RecordingIntegrationTests {
    @Test func recordsAreaAndDisplayAndExportsGIF() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Screen recording permission is missing")

        let screen = try #require(NSScreen.screens.first)
        let displayID = try #require(ScreenGeometry.displayID(of: screen))
        let area = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 641, height: 401)

        for selection in [ScreenSelection.area(area), .display(id: displayID, frame: screen.frame)] {
            let recorder = ScreenRecordingService()
            var options = RecordingOptions()
            options.framesPerSecond = 30
            try await recorder.start(selection, options: options, visibleOwnWindowNumbers: [])
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let url = try await recorder.stop()

            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            #expect(duration > 1)
            #expect(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0)

            let gifURL = url.deletingPathExtension().appendingPathExtension("gif")
            _ = try await GifExporter.export(videoURL: url, to: gifURL, framesPerSecond: 10, maxWidth: 480)
            let source = try #require(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
            #expect(CGImageSourceGetCount(source) >= 15)
        }
    }

    @Test func exportsTrimmedVideoAtLowerResolutionAndFrameRate() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Screen recording permission is missing")
        let screen = try #require(NSScreen.screens.first)
        let displayID = try #require(ScreenGeometry.displayID(of: screen))

        let recorder = ScreenRecordingService()
        try await recorder.start(.display(id: displayID, frame: screen.frame), options: RecordingOptions(), visibleOwnWindowNumbers: [])
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let source = try await recorder.stop()

        let output = source.deletingPathExtension().appendingPathExtension("720.mp4")
        let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), end: CMTime(seconds: 2, preferredTimescale: 600))
        _ = try await VideoExporter.export(videoURL: source, to: output, timeRange: range, removeAudio: true, maxHeight: 720, framesPerSecond: 30)

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let fps = try await track.load(.nominalFrameRate)
        #expect(size.height <= 720)
        #expect(abs(duration - 1.5) < 0.2)
        #expect(fps <= 31)
    }

    @Test func exportsVideoWithBackground() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Screen recording permission is missing")
        let screen = try #require(NSScreen.screens.first)
        let area = CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 800, height: 500)

        let recorder = ScreenRecordingService()
        try await recorder.start(.area(area), options: RecordingOptions(), visibleOwnWindowNumbers: [])
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let source = try await recorder.stop()
        let sourceTrack = try #require(try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first)
        let sourceSize = try await sourceTrack.load(.naturalSize)

        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let style = VideoBackgroundStyle(startColor: red, endColor: red, padding: 80, cornerRadius: 16, shadow: true, aspectRatio: 16.0 / 9.0)
        let output = source.deletingPathExtension().appendingPathExtension("background.mp4")
        _ = try await VideoExporter.export(videoURL: source, to: output, timeRange: nil, removeAudio: true, background: style)

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width > sourceSize.width && size.height > sourceSize.height)
        #expect(abs(size.width / size.height - 16.0 / 9.0) < 0.01)

        let generator = AVAssetImageGenerator(asset: asset)
        let (frame, _) = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        let corner = try #require(frame.cropping(to: CGRect(x: 4, y: 4, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60, "The corner should be the red background")
    }

    @Test func capturesAreaAtNativeResolution() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Screen recording permission is missing")

        let service = ScreenCaptureService()
        let screen = try #require(NSScreen.screens.first)
        let area = CGRect(x: screen.frame.minX + 50, y: screen.frame.minY + 50, width: 300, height: 200)

        let image = try await service.capture(.area(area), options: CaptureOptions())
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(image.size == area.size)
        #expect(CGFloat(pixels.width) == area.width * screen.backingScaleFactor)

        let snapshots = try await service.displaySnapshots()
        #expect(snapshots.count == NSScreen.screens.count)
    }

    @Test func capturesWindowWithAndWithoutShadow() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Screen recording permission is missing")
        let window = try #require(OverlayWindowInfo.onScreenWindows().first, "No visible windows")

        let service = ScreenCaptureService()
        var options = CaptureOptions()

        options.includeWindowShadow = false
        let plain = try await service.capture(.window(id: window.id, frame: window.frame), options: options)
        options.includeWindowShadow = true
        let shadowed = try await service.capture(.window(id: window.id, frame: window.frame), options: options)

        #expect(abs(plain.size.width - window.frame.width) <= 1)
        // The shadow enlarges the image instead of shrinking the window.
        #expect(shadowed.size.width > plain.size.width + 10)
        #expect(shadowed.size.height > plain.size.height + 10)
    }
}
