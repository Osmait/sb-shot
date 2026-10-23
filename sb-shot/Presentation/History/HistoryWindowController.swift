import AppKit
import ImageIO
import SwiftUI

struct HistoryActions {
    let open: (HistoryEntry, URL) -> Void
    let copy: (HistoryEntry, URL) -> Void
    let reveal: (URL) -> Void
}

final class HistoryWindowPresenter: HistoryPresenting {
    private let store: HistoryStore
    private let actions: HistoryActions
    private var controller: HistoryWindowController?

    init(store: HistoryStore, actions: HistoryActions) {
        self.store = store
        self.actions = actions
    }

    func show() {
        if controller == nil {
            let controller = HistoryWindowController(store: store, actions: actions)
            controller.onClose = { [weak self] in self?.controller = nil }
            self.controller = controller
        }
        controller?.show()
    }
}

private final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(store: HistoryStore, actions: HistoryActions) {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Historial de capturas"
        window.minSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.contentView = NSHostingView(rootView: HistoryView(store: store, actions: actions))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible == false {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        onClose?()
    }
}

private struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    let actions: HistoryActions

    @State private var confirmClear = false

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView(
                    "Sin capturas todavía",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Tus capturas y grabaciones aparecerán aquí.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.entries) { entry in
                            HistoryCell(
                                entry: entry,
                                url: store.url(for: entry),
                                actions: actions,
                                onDelete: { store.remove(entry) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Borrar historial", systemImage: "trash")
                }
                .disabled(store.entries.isEmpty)
            }
        }
        .confirmationDialog("¿Borrar todo el historial?", isPresented: $confirmClear) {
            Button("Borrar todo", role: .destructive) { store.clear() }
        } message: {
            Text("Se eliminarán las copias guardadas en el historial. Los archivos que guardaste en tu carpeta no se tocan.")
        }
    }
}

private struct HistoryCell: View {
    let entry: HistoryEntry
    let url: URL
    let actions: HistoryActions
    let onDelete: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.25))

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }

                FileDragSource(fileURL: { url }, previewImage: thumbnail, onDoubleClick: { actions.open(entry, url) })

                if isHovering {
                    HStack(spacing: 6) {
                        cellButton("doc.on.doc", help: "Copiar") { actions.copy(entry, url) }
                        cellButton(entry.kind == .image ? "pencil" : "play.fill", help: "Abrir") { actions.open(entry, url) }
                        cellButton("folder", help: "Mostrar en Finder") { actions.reveal(url) }
                        cellButton("trash", help: "Eliminar", action: onDelete)
                    }
                    .padding(6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
                }

                if entry.kind != .image {
                    Text(entry.kind == .gif ? "GIF" : "VIDEO")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 130)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(isHovering ? 0.25 : 0.08), lineWidth: 1))
            .onHover { isHovering = $0 }

            Text(entry.createdAt, format: .dateTime.day().month().hour().minute())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .task(id: entry.id) {
            thumbnail = await Self.loadThumbnail(for: entry, url: url)
        }
    }

    private func cellButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static func loadThumbnail(for entry: HistoryEntry, url: URL) async -> NSImage? {
        if entry.kind == .video {
            return await VideoExporter.thumbnail(for: url, maxSize: CGSize(width: 480, height: 480))
        }

        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }.value
    }
}
