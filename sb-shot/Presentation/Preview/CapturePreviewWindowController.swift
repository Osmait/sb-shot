import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class CapturePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let image: NSImage
    private let onCopy: () -> Void
    private let onEdit: () -> Void
    private let onClose: () -> Void

    init(image: NSImage, onCopy: @escaping () -> Void, onEdit: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.image = image
        self.onCopy = onCopy
        self.onEdit = onEdit
        self.onClose = onClose

        let contentView = CapturePreviewView(
            image: image,
            onCopy: onCopy,
            onEdit: onEdit,
            onSave: {},
            onClose: {}
        )
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Vista previa"
        window.minSize = NSSize(width: 420, height: 320)
        window.setContentSize(Self.preferredSize(for: image))
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let updatedView = CapturePreviewView(
            image: image,
            onCopy: { [weak self] in
                self?.onCopy()
            },
            onEdit: { [weak self] in
                self?.onEdit()
            },
            onSave: { [weak self] in
                self?.saveImage()
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        hostingController.rootView = updatedView
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func saveImage() {
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
        panel.nameFieldStringValue = "captura.png"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? pngData.write(to: url)
    }

    private static func preferredSize(for image: NSImage) -> NSSize {
        let width = min(max(image.size.width + 80, 520), 1300)
        let height = min(max(image.size.height + 140, 380), 900)
        return NSSize(width: width, height: height)
    }
}

private struct CapturePreviewView: View {
    let image: NSImage
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Vista previa")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.08))

                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width - 12, height: proxy.size.height - 12)
                }
            }

            HStack {
                Button("Cerrar") {
                    onClose()
                }

                Spacer()

                Button("Guardar PNG") {
                    onSave()
                }

                Button {
                    onEdit()
                } label: {
                    Label("Editar", systemImage: "pencil")
                }

                Button("Copiar") {
                    onCopy()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}
