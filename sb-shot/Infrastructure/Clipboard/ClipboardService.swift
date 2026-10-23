import AppKit

struct ClipboardService {
    func copy(image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        if
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        {
            item.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
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

extension ClipboardService: ClipboardWriting {}
