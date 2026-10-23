import AppKit

/// Portapapeles con datos ya codificados, para no volver a codificar la imagen.
protocol ImageFileClipboardWriting: ClipboardWriting {
    func copy(pngData: Data, fileURL: URL?)
    /// Copia la imagen de un archivo (PNG y referencia al archivo). Devuelve `false` si no se pudo leer.
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

        // PNG para pegar la imagen y la URL del archivo para pegarlo en Finder o adjuntarlo.
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

        // Otros formatos (JPEG) se convierten a PNG, que es lo que aceptan todas las apps.
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
