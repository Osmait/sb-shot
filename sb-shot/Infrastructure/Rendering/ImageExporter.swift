import AppKit
import UniformTypeIdentifiers

enum ImageExporter {
    static func savePNG(_ image: NSImage, defaultName: String = "captura.png") {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pngData.write(to: url)
    }
}
