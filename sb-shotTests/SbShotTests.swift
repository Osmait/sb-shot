//
//  SbShotTests.swift
//  sb-shotTests
//
//  Created by Jose Saul Burgos on 3/4/26.
//

import AppKit
@testable import SbShot
import Testing

struct SbShotTests {
    @Test func captureRegionCopiesImageWhenSuccessful() async {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        let permissions = MockPermissions(preflight: true, requestResult: true)
        let selector = MockSelector(result: CGRect(x: 10, y: 10, width: 50, height: 40))
        let capturer = MockCapturer(result: .success(image))
        let clipboard = MockClipboard()

        let useCase = CaptureRegionUseCase(
            permissions: permissions,
            selector: selector,
            capturer: capturer,
            clipboard: clipboard
        )

        let outcome = await useCase.execute()

        guard case let .captured(capturedImage) = outcome else {
            Issue.record("Expected capture outcome")
            return
        }

        #expect(capturedImage.size == image.size)
        #expect(clipboard.copyCount == 1)
    }

    @Test func captureRegionRequestsPermissionAndOpensSettingsWhenDenied() async {
        let permissions = MockPermissions(preflight: false, requestResult: false)
        let selector = MockSelector(result: nil)
        let capturer = MockCapturer(result: .failure(MockError.captureFailed))
        let clipboard = MockClipboard()

        let useCase = CaptureRegionUseCase(
            permissions: permissions,
            selector: selector,
            capturer: capturer,
            clipboard: clipboard
        )

        let outcome = await useCase.execute()

        guard case .permissionDenied = outcome else {
            Issue.record("Expected permission denied outcome")
            return
        }

        #expect(permissions.requestCount == 1)
        #expect(permissions.openSettingsCount == 1)
        #expect(clipboard.copyCount == 0)
    }

    @Test func captureRegionReturnsCancelledWhenSelectionIsCancelled() async {
        let permissions = MockPermissions(preflight: true, requestResult: true)
        let selector = MockSelector(result: nil)
        let capturer = MockCapturer(result: .failure(MockError.captureFailed))
        let clipboard = MockClipboard()

        let useCase = CaptureRegionUseCase(
            permissions: permissions,
            selector: selector,
            capturer: capturer,
            clipboard: clipboard
        )

        let outcome = await useCase.execute()

        guard case .cancelled = outcome else {
            Issue.record("Expected cancelled outcome")
            return
        }

        #expect(capturer.captureCount == 0)
        #expect(clipboard.copyCount == 0)
    }
}

private enum MockError: Error {
    case captureFailed
}

private final class MockPermissions: ScreenPermissionChecking {
    let preflight: Bool
    let requestResult: Bool

    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    init(preflight: Bool, requestResult: Bool) {
        self.preflight = preflight
        self.requestResult = requestResult
    }

    func hasScreenRecordingAccess() -> Bool {
        preflight
    }

    func requestScreenRecordingAccess() -> Bool {
        requestCount += 1
        return requestResult
    }

    func openScreenRecordingSettings() {
        openSettingsCount += 1
    }
}

private final class MockSelector: RegionSelecting {
    let result: CGRect?

    init(result: CGRect?) {
        self.result = result
    }

    func selectRegion() async -> CGRect? {
        result
    }
}

private final class MockCapturer: ScreenCaptureProviding {
    let result: Result<NSImage, Error>
    private(set) var captureCount = 0

    init(result: Result<NSImage, Error>) {
        self.result = result
    }

    func captureRegion(_: CGRect) async throws -> NSImage {
        captureCount += 1
        return try result.get()
    }
}

private final class MockClipboard: ClipboardWriting {
    private(set) var copyCount = 0

    func copy(image _: NSImage) {
        copyCount += 1
    }
}
