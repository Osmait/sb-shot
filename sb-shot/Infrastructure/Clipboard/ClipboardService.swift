import AppKit

/// Clipboard with already encoded data, to avoid re-encoding the image.
protocol ImageFileClipboardWriting: ClipboardWriting {
    func copy(pngData: Data, fileURL: URL?)
    /// Copies the image of a file (PNG plus a file reference). Returns `false` if it could not be read.
    @discardableResult
    func copyImageFile(at url: URL) -> Bool
}

struct ClipboardService {
    func copy(image: NSImage) {
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return }
        copy(pngData: png, fileURL: nil)
    }

    func copy(pngData: Data, fileURL: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // PNG to paste the image, and the file URL to paste it in Finder or attach it.
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        pasteboard.writeObjects([item])
    }

    @discardableResult
    func copyImageFile(at url: URL) -> Bool {
        if url.pathExtension.lowercased() == "png", let data = try? Data(contentsOf: url) {
            copy(pngData: data, fileURL: url)
            return true
        }

        // Other formats (JPEG) are converted to PNG, which every app accepts.
        guard
            let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return false }
        copy(pngData: png, fileURL: url)
        return true
    }

    func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copy(fileURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
    }
}

extension ClipboardService: ImageFileClipboardWriting {}
