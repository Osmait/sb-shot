import AppKit
import SwiftUI

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
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
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
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        onClose()
    }

    private func saveImage() {
        ImageExporter.savePNG(image)
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
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack {
                    EditorColors.canvasBackground

                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width - 40, height: proxy.size.height - 20)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 4)
                }
            }
            .padding(.top, 38)

            bottomBar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .background(EditorColors.canvasBackground)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(PreviewToolButtonStyle())

            Spacer()

            Text("\(Int(image.size.width)) \u{00D7} \(Int(image.size.height))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button("Guardar") {
                onSave()
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false))

            Button {
                onEdit()
            } label: {
                Label("Editar", systemImage: "pencil")
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false))

            Button("Copiar") {
                onCopy()
            }
            .buttonStyle(ActionButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EditorColors.groupBorder, lineWidth: 1))
    }
}
