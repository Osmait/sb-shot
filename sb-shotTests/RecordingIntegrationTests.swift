import AppKit
import AVFoundation
@testable import SbShot
import Testing

/// Pruebas de integracion reales: capturan y graban la pantalla principal.
/// Requieren permiso de grabacion de pantalla y la sesion desbloqueada, por eso solo se ejecutan con:
///
///     TEST_RUNNER_SBSHOT_INTEGRATION=1 xcodebuild test -scheme SbShot -only-testing:SbShotTests/RecordingIntegrationTests
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SBSHOT_INTEGRATION"] != nil))
struct RecordingIntegrationTests {
    @Test func recordsAreaAndDisplayAndExportsGIF() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Falta el permiso de grabación de pantalla")

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
        try #require(CGPreflightScreenCaptureAccess(), "Falta el permiso de grabación de pantalla")
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

    @Test func capturesAreaAtNativeResolution() async throws {
        try #require(CGPreflightScreenCaptureAccess(), "Falta el permiso de grabación de pantalla")

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
        try #require(CGPreflightScreenCaptureAccess(), "Falta el permiso de grabación de pantalla")
        let window = try #require(OverlayWindowInfo.onScreenWindows().first, "No hay ventanas visibles")

        let service = ScreenCaptureService()
        var options = CaptureOptions()

        options.includeWindowShadow = false
        let plain = try await service.capture(.window(id: window.id, frame: window.frame), options: options)
        options.includeWindowShadow = true
        let shadowed = try await service.capture(.window(id: window.id, frame: window.frame), options: options)

        #expect(abs(plain.size.width - window.frame.width) <= 1)
        // La sombra agranda la imagen en lugar de encoger la ventana.
        #expect(shadowed.size.width > plain.size.width + 10)
        #expect(shadowed.size.height > plain.size.height + 10)
    }
}
