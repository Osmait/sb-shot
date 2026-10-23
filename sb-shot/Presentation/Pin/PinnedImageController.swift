import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Mantiene capturas flotando sobre todas las ventanas.
final class PinnedImagePresenter: PinPresenting {
    private var controllers: [PinnedImageController] = []

    func pin(image: NSImage, onEdit: @escaping (NSImage) -> Void, onCopy: @escaping (NSImage) -> Void) {
        let controller = PinnedImageController(image: image, onEdit: onEdit, onCopy: onCopy)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.show()
    }
}

private final class PinnedImageController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let image: NSImage
    private let panel: PinPanel
    private let model = PinViewModel()
    private let aspectRatio: CGFloat

    init(image: NSImage, onEdit: @escaping (NSImage) -> Void, onCopy: @escaping (NSImage) -> Void) {
        self.image = image
        aspectRatio = image.size.width / max(image.size.height, 1)

        let screen = ScreenGeometry.screenUnderCursor?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let maxSize = CGSize(width: screen.width * 0.5, height: screen.height * 0.5)
        let ratio = min(maxSize.width / max(image.size.width, 1), maxSize.height / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)

        panel = PinPanel(
            contentRect: CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        panel.minSize = CGSize(width: 60, height: 60 / max(aspectRatio, 0.01))
        panel.delegate = self

        let view = PinView(
            image: image,
            model: model,
            onClose: { [weak self] in self?.panel.close() },
            onCopy: { onCopy(image) },
            onEdit: { [weak self] in
                onEdit(image)
                self?.panel.close()
            },
            onSave: { [weak self] in self?.save() }
        )

        let container = ZoomContainerView(frame: CGRect(origin: .zero, size: size))
        container.onZoom = { [weak self] factor in self?.zoom(by: factor) }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        panel.onEscape = { [weak self] in self?.panel.close() }
    }

    func show() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func windowWillClose(_: Notification) {
        onClose?()
    }

    private func zoom(by factor: CGFloat) {
        let frame = panel.frame
        let newWidth = min(max(frame.width * factor, 60), 4000)
        let newHeight = newWidth / max(aspectRatio, 0.01)
        let newFrame = CGRect(
            x: frame.midX - newWidth / 2,
            y: frame.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
        panel.setFrame(newFrame, display: true)
        model.zoomPercent = Int((newWidth / max(image.size.width, 1) * 100).rounded())
        model.flashZoom()
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "captura-fijada.png"
        NSApp.activate(ignoringOtherApps: true)
        guard
            panel.runModal() == .OK,
            let url = panel.url,
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }
}

private final class PinPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override func cancelOperation(_: Any?) {
        onEscape?()
    }
}

/// Recibe la rueda del raton y el gesto de pellizco para cambiar el tamano de la captura fijada.
private final class ZoomContainerView: NSView {
    var onZoom: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard delta != 0 else { return }
        onZoom?(1 + delta / 300)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification)
    }
}

private final class PinViewModel: ObservableObject {
    @Published var opacity: Double = 1
    @Published var zoomPercent = 100
    @Published var showsZoom = false

    private var zoomTask: Task<Void, Never>?

    func flashZoom() {
        showsZoom = true
        zoomTask?.cancel()
        zoomTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            self?.showsZoom = false
        }
    }
}

private struct PinView: View {
    let image: NSImage
    @ObservedObject var model: PinViewModel
    let onClose: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(model.opacity)
                .gesture(WindowDragGesture())

            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.opacity)
            }

            if model.showsZoom {
                Text("\(model.zoomPercent)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.65), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .overlay(Rectangle().strokeBorder(Color.white.opacity(isHovering ? 0.4 : 0.15), lineWidth: 1))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .contextMenu {
            Button("Copiar", action: onCopy)
            Button("Guardar…", action: onSave)
            Button("Anotar", action: onEdit)
            Menu("Opacidad") {
                ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { value in
                    Button("\(Int(value * 100))%") { model.opacity = value }
                }
            }
            Divider()
            Button("Cerrar", action: onClose)
        }
    }
}
