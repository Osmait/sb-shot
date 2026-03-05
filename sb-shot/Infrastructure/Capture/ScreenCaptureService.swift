import AppKit
import CoreGraphics
import ScreenCaptureKit

struct ScreenCaptureService {
    private enum CaptureError: Error {
        case emptyResult
    }

    func captureRegion(_ globalRect: CGRect) async throws -> NSImage {
        let selection = globalRect.standardized.integral
        guard selection.width > 1, selection.height > 1 else { throw CaptureError.emptyResult }
        return try await captureWithScreenCaptureKit(selection: selection)
    }

    private func captureWithScreenCaptureKit(selection: CGRect) async throws -> NSImage {
        let screens = NSScreen.screens
        let topY = screens.map(\ .frame.maxY).max() ?? selection.maxY
        let selectionTopLeft = CGRect(
            x: selection.minX,
            y: topY - selection.maxY,
            width: selection.width,
            height: selection.height
        )

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var chunks: [(image: NSImage, destination: CGRect)] = []

        for display in content.displays {
            let overlap = selectionTopLeft.intersection(display.frame)
            if overlap.isNull || overlap.isEmpty { continue }

            let localSourceRect = CGRect(
                x: overlap.minX - display.frame.minX,
                y: overlap.minY - display.frame.minY,
                width: overlap.width,
                height: overlap.height
            )

            let displayScale = CGFloat(display.width) / max(display.frame.width, 1)

            let config = SCStreamConfiguration()
            config.sourceRect = localSourceRect
            config.width = Int(max(1, localSourceRect.width * displayScale))
            config.height = Int(max(1, localSourceRect.height * displayScale))

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let capture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let piece = NSImage(cgImage: capture, size: overlap.size)
            let destination = CGRect(
                x: overlap.minX - selectionTopLeft.minX,
                y: overlap.minY - selectionTopLeft.minY,
                width: overlap.width,
                height: overlap.height
            )

            chunks.append((piece, destination))
        }

        guard !chunks.isEmpty else {
            throw CaptureError.emptyResult
        }

        let output = NSImage(size: selection.size)
        output.lockFocusFlipped(true)
        for chunk in chunks {
            chunk.image.draw(in: chunk.destination)
        }
        output.unlockFocus()

        return output
    }
}

extension ScreenCaptureService: ScreenCaptureProviding {}
