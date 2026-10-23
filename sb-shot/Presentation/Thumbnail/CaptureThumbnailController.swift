import AppKit
import SwiftUI

final class CaptureThumbnailController: NSWindowController, NSWindowDelegate {
    private let autoCloseDelay: UInt64 = 5_000_000_000
    private let onClose: () -> Void
    private var autoCloseTask: Task<Void, Never>?

    init(image: NSImage, onOpen: @escaping () -> Void, onEdit: @escaping () -> Void, onCopy: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let view = CaptureThumbnailView(
            image: image,
            onOpen: onOpen,
            onEdit: onEdit,
            onCopy: onCopy,
            onClose: {},
            onHoverChanged: { _ in }
        )

        let hostingController = NSHostingController(rootView: view)
        let panel = NSPanel(contentViewController: hostingController)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 290, height: 230))

        super.init(window: panel)
        panel.delegate = self

        let updatedView = CaptureThumbnailView(
            image: image,
            onOpen: { [weak self] in
                onOpen()
                self?.close()
            },
            onEdit: { [weak self] in
                onEdit()
                self?.close()
            },
            onCopy: {
                onCopy()
            },
            onClose: { [weak self] in
                self?.close()
            },
            onHoverChanged: { [weak self] isHovering in
                self?.handleHoverChange(isHovering: isHovering)
            }
        )
        hostingController.rootView = updatedView
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let panel = window as? NSPanel else { return }
        panel.setFrameOrigin(Self.targetOrigin(for: panel.frame.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        scheduleAutoClose()
    }

    override func close() {
        autoCloseTask?.cancel()
        super.close()
    }

    func windowWillClose(_: Notification) {
        onClose()
    }

    private func closeWithFade() {
        guard let panel = window as? NSPanel else {
            close()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.close()
        }
    }

    private func handleHoverChange(isHovering: Bool) {
        if isHovering {
            autoCloseTask?.cancel()
        } else {
            scheduleAutoClose()
        }
    }

    private func scheduleAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: autoCloseDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.closeWithFade()
            }
        }
    }

    private static func targetOrigin(for size: NSSize) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 16

        return CGPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        )
    }
}

private struct CaptureThumbnailView: View {
    let image: NSImage
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                onOpen()
            } label: {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 290, height: 230)
                    .clipped()
            }
            .buttonStyle(.plain)

            HStack(spacing: 6) {
                actionButton(systemName: "doc.on.doc", action: onCopy)
                actionButton(systemName: "pencil", action: onEdit)
                actionButton(systemName: "arrow.up.left.and.arrow.down.right", action: onOpen)
                actionButton(systemName: "xmark", action: onClose)
            }
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1)
            )
            .padding(10)
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.16), value: isHovering)
        }
        .frame(width: 290, height: 230)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged(hovering)
        }
    }

    private func actionButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(Color.white)
                .background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
