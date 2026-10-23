import AppKit
import SwiftUI

/// Aviso flotante breve en la parte inferior de la pantalla ("Copiado", "Guardado"...).
final class ToastController: ToastPresenting {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String) {
        present(ToastView(message: message, systemImage: systemImage, showsProgress: false))
        scheduleHide(after: 1.6)
    }

    func showProgress(_ message: String) {
        present(ToastView(message: message, systemImage: nil, showsProgress: true))
        hideTask?.cancel()
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard self?.panel === panel else { return }
                panel.orderOut(nil)
                self?.panel = nil
            }
        }
    }

    private func present(_ view: ToastView) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = panel ?? Self.makePanel()
        panel.contentView = hosting
        panel.setContentSize(size)

        let screen = ScreenGeometry.screenUnderCursor
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 90))

        if self.panel == nil {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        self.panel = panel
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

private struct ToastView: View {
    let message: String
    let systemImage: String?
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(message)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .padding(16)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
