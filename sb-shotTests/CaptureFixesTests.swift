import AppKit
@testable import SbShot
import Testing

// MARK: - Dobles propios (los de SbShotTests.swift son privados)

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

/// `displaySnapshots` queda suspendido hasta que alguien reanude la continuacion.
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

// MARK: - Helpers de imagenes

private func makeRGBAImage(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(context)
    return context.makeImage()!
}

/// Lee un pixel RGBA (origen arriba a la izquierda) redibujando la imagen en un buffer conocido.
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

// MARK: - 1 y 2: caso de uso

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
        // Instantanea 2x de un area de 100x50 pt: 200x100 px.
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

// MARK: - 3: selector con flag de ocupado

@MainActor
struct SelectionOverlayRegionSelectorBusyTests {
    /// La primera llamada queda suspendida en `displaySnapshots` (nunca se reanuda, para no abrir overlays reales
    /// al terminar); la segunda debe devolver nil de inmediato sin pedir otra captura.
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
        // Con congelado + ocultar iconos, se pide la instantanea sin iconos.
        #expect(capturer.hidingFlags == [true])
        _ = first
    }
}

// MARK: - 4: recorte y composicion

@MainActor
struct ScreenCaptureImageProcessingTests {
    @Test func trimsTransparentMarginsToOpaqueBounds() async throws {
        // 40x30 transparente con un bloque opaco x 10..<25, y 5..<20 (origen arriba-izquierda).
        let image = makeRGBAImage(width: 40, height: 30) { context in
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            // CGContext tiene origen abajo: y superior 5 => y inferior = 30 - 20 = 10.
            context.fill(CGRect(x: 10, y: 10, width: 15, height: 15))
        }

        let trimmed = try #require(await ScreenCaptureService.trimmingTransparentEdges(image))

        #expect(trimmed.width == 15)
        #expect(trimmed.height == 15)
        #expect(pixel(trimmed, x: 0, y: 0).a == 255)
        #expect(pixel(trimmed, x: 14, y: 14).a == 255)
    }

    @Test func trimKeepsAsymmetricMarginsPositionCorrect() async throws {
        // Franja opaca de 4x2 pegada al borde superior izquierdo, resto transparente.
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
        // Lienzo 20x10 pt; rojo a la izquierda, azul a la derecha (coordenadas con origen arriba).
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
        // Lienzo 10x10 pt a 2x = 20x20 px; el trozo ocupa la mitad inferior (y=5..10 pt, origen arriba).
        let chunks: [(image: CGImage, destination: CGRect)] = [(green, CGRect(x: 0, y: 5, width: 10, height: 5))]

        let composed = try await ScreenCaptureService.compose(chunks, size: CGSize(width: 10, height: 10), scale: 2)

        #expect(composed.width == 20)
        #expect(composed.height == 20)
        #expect(pixel(composed, x: 10, y: 15).g > 240)
        #expect(pixel(composed, x: 10, y: 3).a == 0)
    }
}
