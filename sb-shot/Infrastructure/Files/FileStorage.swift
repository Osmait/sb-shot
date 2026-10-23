import AppKit
import UniformTypeIdentifiers

/// Archivos temporales, carpeta de guardado (con bookmark de sandbox) y codificacion de imagenes.
final class FileStorage {
    let temporaryDirectory: URL

    private let defaults: UserDefaults
    private let bookmarkKey = "sbshot.saveFolderBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("sb-shot", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Names

    func fileName(prefix: String, fileExtension: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        let cleanPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleanPrefix.isEmpty ? formatter.string(from: date) : "\(cleanPrefix) \(formatter.string(from: date))"
        return "\(base).\(fileExtension)"
    }

    func temporaryURL(prefix: String, fileExtension: String) -> URL {
        uniqueURL(in: temporaryDirectory, fileName: fileName(prefix: prefix, fileExtension: fileExtension))
    }

    // MARK: - Images

    func encode(_ image: NSImage, as format: ImageFileFormat) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // Conserva el tamano en puntos para que las capturas Retina se abran al tamano correcto.
        bitmap.size = image.size

        switch format {
        case .png:
            return bitmap.representation(using: .png, properties: [:])
        case .jpeg:
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    func writeTemporary(_ image: NSImage, format: ImageFileFormat, prefix: String) throws -> URL {
        guard let data = encode(image, as: format) else { throw CocoaError(.fileWriteUnknown) }
        let url = temporaryURL(prefix: prefix, fileExtension: format.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Save folder

    var defaultSaveFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("sb-shot", isDirectory: true)
    }

    var saveFolder: URL {
        resolvedBookmark() ?? defaultSaveFolder
    }

    var hasCustomSaveFolder: Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    var saveFolderDisplayPath: String {
        (saveFolder.path as NSString).abbreviatingWithTildeInPath
    }

    @discardableResult
    func chooseSaveFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Elegir"
        panel.message = "Elige la carpeta donde se guardaran las capturas y grabaciones."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        defaults.set(bookmark, forKey: bookmarkKey)
        return true
    }

    func resetSaveFolder() {
        defaults.removeObject(forKey: bookmarkKey)
    }

    /// Copia el archivo a la carpeta de guardado y devuelve su nueva ubicacion.
    func saveToFolder(_ file: URL, fileName: String? = nil) throws -> URL {
        let folder = saveFolder
        let isScoped = folder.startAccessingSecurityScopedResource()
        defer {
            if isScoped {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = uniqueURL(in: folder, fileName: fileName ?? file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Pide una ubicacion con el panel de guardado y copia el archivo ahi.
    func saveWithPanel(_ file: URL, suggestedName: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName ?? file.lastPathComponent
        if let type = UTType(filenameExtension: file.pathExtension) {
            panel.allowedContentTypes = [type]
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.copyItem(at: file, to: url)
            return url
        } catch {
            return nil
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Private

    private func resolvedBookmark() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }

        if isStale, let refreshed = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(refreshed, forKey: bookmarkKey)
        }
        return url
    }

    private func uniqueURL(in folder: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}
