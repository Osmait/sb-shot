import AppKit
@testable import SbShot
import Testing

// MARK: - Own test doubles (the ones in SbShotTests.swift are private)

private final class FixPermissions: ScreenPermissionChecking {
    let alreadyRequested: Bool
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(alreadyRequested: Bool) {
        self.alreadyRequested = alreadyRequested
    }

    func hasScreenRecordingAccess() -> Bool { false }
    func requestScreenRecordingAccess() -> Bool {
        requestCount += 1
        return false
    }

    func openScreenRecordingSettings() {
        openSettingsCount += 1
    }

    func hasRequestedScreenRecordingAccess() -> Bool { alreadyRequested }
}

private final class FixSelector: RegionSelecting {
    let result: SelectionResult?
    private(set) var receivedOptions: SelectionOptions?

    init(result: SelectionResult?) {
        self.result = result
    }

    func select(options: SelectionOptions) async -> SelectionResult? {
        receivedOptions = options
        return result
    }

    func displayUnderCursor() -> ScreenSelection? { nil }
}

private final class FixCapturer: ScreenCaptureProviding {
    private(set) var captureCount = 0
    func displaySnapshots() async throws -> [CGDirectDisplayID: CGImage] { [:] }
    func capture(_: ScreenSelection, options _: CaptureOptions) async throws -> NSImage {
        captureCount += 1
        return NSImage(size: NSSize(width: 1, height: 1))
    }
}

/// `displaySnapshots` stays suspended until someone resumes the continuation.
private final class SuspendingCapturer: ScreenCaptureProviding {
    private(set) var snapshotCalls = 0
    private(set) var hidingFlags: [Bool] = []
    private var continuation: CheckedContinuation<[CGDirectDisplayID: CGImage], Error>?

    func displaySnapshots() async throws -> [CGDirectDisplayID: CGImage] {
        try await displaySnapshots(hidingDesktopIcons: false)
    }

    func displaySnapshots(hidingDesktopIcons: Bool) async throws -> [CGDirectDisplayID: CGImage] {
        snapshotCalls += 1
        hidingFlags.append(hidingDesktopIcons)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func capture(_: ScreenSelection, options _: CaptureOptions) async throws -> NSImage {
        NSImage(size: .zero)
    }
}

// MARK: - Image helpers

private func makeRGBAImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(context)
    return context.makeImage()!
}

/// Reads an RGBA pixel (top-left origin) by redrawing the image into a known buffer.
private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let i = (y * image.width + x) * 4
    return (data[i], data[i + 1], data[i + 2], data[i + 3])
}

// MARK: - 1 and 2: use case

@MainActor
struct CaptureFixesUseCaseTests {
    private let area = CGRect(x: 0, y: 0, width: 100, height: 50)

    private func makeUseCase(
        permissions: FixPermissions,
        selector: FixSelector = FixSelector(result: nil),
        capturer: FixCapturer = FixCapturer()
    ) -> CaptureScreenshotUseCase {
        CaptureScreenshotUseCase(permissions: permissions, selector: selector, capturer: capturer, countdown: nil)
    }

    @Test func firstDeniedRequestDoesNotOpenSettings() async {
        let permissions = FixPermissions(alreadyRequested: false)
        let outcome = await makeUseCase(permissions: permissions).execute(mode: .area)

        guard case .permissionDenied = outcome else {
            Issue.record("Expected permission denied")
            return
        }
        #expect(permissions.requestCount == 1)
        #expect(permissions.openSettingsCount == 0)
    }

    @Test func laterDeniedRequestOpensSettings() async {
        let permissions = FixPermissions(alreadyRequested: true)
        let outcome = await makeUseCase(permissions: permissions).execute(mode: .area)

        guard case .permissionDenied = outcome else {
            Issue.record("Expected permission denied")
            return
        }
        #expect(permissions.requestCount == 1)
        #expect(permissions.openSettingsCount == 1)
    }

    @Test func frozenImageIsDownscaledToOnePixelPerPointWhenRequested() async throws {
        // 2x snapshot of a 100x50 pt area: 200x100 px.
        let cg = makeRGBAImage(width: 200, height: 100) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let frozen = NSImage(cgImage: cg, size: NSSize(width: 100, height: 50))
        let selector = FixSelector(result: SelectionResult(selection: .area(area), frozenImage: frozen))
        let granted = CaptureScreenshotUseCase(
            permissions: GrantedPermissions(), selector: selector, capturer: FixCapturer(), countdown: nil
        )

        let outcome = await granted.execute(mode: .area, captureOptions: CaptureOptions(downscaleToOneX: true))

        guard case let .captured(image, _) = outcome else {
            Issue.record("Expected capture")
            return
        }
        let result = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(result.width == 100)
        #expect(result.height == 50)
        #expect(image.size == NSSize(width: 100, height: 50))
        #expect(pixel(result, x: 50, y: 25).r > 240)
    }

    @Test func frozenImageKeepsRetinaResolutionWithoutDownscale() async throws {
        let cg = makeRGBAImage(width: 200, height: 100) { _ in }
        let frozen = NSImage(cgImage: cg, size: NSSize(width: 100, height: 50))
        let selector = FixSelector(result: SelectionResult(selection: .area(area), frozenImage: frozen))
        let granted = CaptureScreenshotUseCase(
            permissions: GrantedPermissions(), selector: selector, capturer: FixCapturer(), countdown: nil
        )

        let outcome = await granted.execute(mode: .area)

        guard case let .captured(image, _) = outcome else {
            Issue.record("Expected capture")
            return
        }
        #expect(image === frozen)
    }

    @Test func hidesDesktopIconsIsPropagatedToSelectionOptions() async {
        let selector = FixSelector(result: nil)
        let granted = CaptureScreenshotUseCase(
            permissions: GrantedPermissions(), selector: selector, capturer: FixCapturer(), countdown: nil
        )

        _ = await granted.execute(
            mode: .area,
            selectionOptions: SelectionOptions(freezeScreen: true),
            captureOptions: CaptureOptions(hideDesktopIcons: true)
        )

        #expect(selector.receivedOptions?.hidesDesktopIcons == true)
        #expect(selector.receivedOptions?.freezeScreen == true)

        _ = await granted.execute(mode: .area, captureOptions: CaptureOptions(hideDesktopIcons: false))
        #expect(selector.receivedOptions?.hidesDesktopIcons == false)
    }
}

private struct GrantedPermissions: ScreenPermissionChecking {
    func hasScreenRecordingAccess() -> Bool { true }
    func requestScreenRecordingAccess() -> Bool { true }
    func openScreenRecordingSettings() {}
}

// MARK: - 3: selector with busy flag

@MainActor
struct SelectionOverlayRegionSelectorBusyTests {
    /// The first call stays suspended in `displaySnapshots` (never resumed, so no real overlays are opened
    /// when finished); the second must return nil immediately without requesting another capture.
    @Test func secondSelectWhileFirstAwaitsSnapshotsReturnsNil() async {
        let capturer = SuspendingCapturer()
        let selector = SelectionOverlayRegionSelector(capturer: capturer)
        var options = SelectionOptions()
        options.freezeScreen = true
        options.hidesDesktopIcons = true

        let first = Task { await selector.select(options: options) }
        while capturer.snapshotCalls == 0 { await Task.yield() }

        let second = await selector.select(options: options)

        #expect(second == nil)
        #expect(capturer.snapshotCalls == 1)
        // With freeze + hide icons, the snapshot is requested without icons.
        #expect(capturer.hidingFlags == [true])
        _ = first
    }
}

// MARK: - 4: cropping and compositing

@MainActor
struct ScreenCaptureImageProcessingTests {
    @Test func trimsTransparentMarginsToOpaqueBounds() async throws {
        // 40x30 transparent with an opaque block x 10..<25, y 5..<20 (top-left origin).
        let image = makeRGBAImage(width: 40, height: 30) { context in
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            // CGContext has a bottom origin: top y 5 => bottom y = 30 - 20 = 10.
            context.fill(CGRect(x: 10, y: 10, width: 15, height: 15))
        }

        let trimmed = try #require(await ScreenCaptureService.trimmingTransparentEdges(image))

        #expect(trimmed.width == 15)
        #expect(trimmed.height == 15)
        #expect(pixel(trimmed, x: 0, y: 0).a == 255)
        #expect(pixel(trimmed, x: 14, y: 14).a == 255)
    }

    @Test func trimKeepsAsymmetricMarginsPositionCorrect() async throws {
        // Opaque 4x2 strip at the top-left edge, rest transparent.
        let image = makeRGBAImage(width: 20, height: 10) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 8, width: 4, height: 2))
        }

        let trimmed = try #require(await ScreenCaptureService.trimmingTransparentEdges(image))

        #expect(trimmed.width == 4)
        #expect(trimmed.height == 2)
    }

    @Test func opaqueImageIsUnchanged() async throws {
        let image = makeRGBAImage(width: 16, height: 12) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }

        let trimmed = try #require(await ScreenCaptureService.trimmingTransparentEdges(image))

        #expect(trimmed.width == 16)
        #expect(trimmed.height == 12)
    }

    @Test func fullyTransparentImageReturnsNilWithoutCrashing() async {
        let image = makeRGBAImage(width: 10, height: 10) { _ in }

        let trimmed = await ScreenCaptureService.trimmingTransparentEdges(image)

        #expect(trimmed == nil)
    }

    @Test func composePlacesChunksAtTheirDestination() async throws {
        let red = makeRGBAImage(width: 10, height: 10) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let blue = makeRGBAImage(width: 10, height: 10) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        // Canvas 20x10 pt; red on the left, blue on the right (top-origin coordinates).
        let chunks: [(image: CGImage, destination: CGRect)] = [
            (red, CGRect(x: 0, y: 0, width: 10, height: 10)),
            (blue, CGRect(x: 10, y: 0, width: 10, height: 10)),
        ]

        let composed = try await ScreenCaptureService.compose(chunks, size: CGSize(width: 20, height: 10), scale: 1)

        #expect(composed.width == 20)
        #expect(composed.height == 10)
        let left = pixel(composed, x: 2, y: 5)
        let right = pixel(composed, x: 17, y: 5)
        #expect(left.r > 240 && left.b < 15)
        #expect(right.b > 240 && right.r < 15)
    }

    @Test func composeAppliesScaleAndVerticalFlip() async throws {
        let green = makeRGBAImage(width: 20, height: 20) { context in
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        // Canvas 10x10 pt at 2x = 20x20 px; the piece fills the bottom half (y=5..10 pt, top origin).
        let chunks: [(image: CGImage, destination: CGRect)] = [(green, CGRect(x: 0, y: 5, width: 10, height: 5))]

        let composed = try await ScreenCaptureService.compose(chunks, size: CGSize(width: 10, height: 10), scale: 2)

        #expect(composed.width == 20)
        #expect(composed.height == 20)
        #expect(pixel(composed, x: 10, y: 15).g > 240)
        #expect(pixel(composed, x: 10, y: 3).a == 0)
    }
}
