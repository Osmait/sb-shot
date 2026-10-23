import AppKit
import Combine

struct HistoryEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case image
        case video
        case gif
    }

    let id: UUID
    let fileName: String
    let kind: Kind
    let createdAt: Date
}

/// Guarda una copia de cada captura y grabacion en Application Support para el historial.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    let directory: URL
    private let indexURL: URL
    private let limit: Int

    init(limit: Int = 100) {
        self.limit = limit
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = support.appendingPathComponent("sb-shot/History", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func add(fileURL: URL, kind: HistoryEntry.Kind) {
        let id = UUID()
        let fileName = "\(id.uuidString).\(fileURL.pathExtension)"
        let destination = directory.appendingPathComponent(fileName)

        do {
            try FileManager.default.copyItem(at: fileURL, to: destination)
        } catch {
            return
        }

        entries.insert(HistoryEntry(id: id, fileName: fileName, kind: kind, createdAt: Date()), at: 0)
        trim()
        persist()
    }

    func url(for entry: HistoryEntry) -> URL {
        directory.appendingPathComponent(entry.fileName)
    }

    func remove(_ entry: HistoryEntry) {
        try? FileManager.default.removeItem(at: url(for: entry))
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        for entry in entries {
            try? FileManager.default.removeItem(at: url(for: entry))
        }
        entries.removeAll()
        persist()
    }

    private func trim() {
        guard entries.count > limit else { return }
        for entry in entries[limit...] {
            try? FileManager.default.removeItem(at: url(for: entry))
        }
        entries = Array(entries.prefix(limit))
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }

        entries = decoded.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
