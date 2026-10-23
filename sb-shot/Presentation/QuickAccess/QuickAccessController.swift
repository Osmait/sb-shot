import AppKit
import SwiftUI

/// Pila de miniaturas flotantes que aparece despues de cada captura o grabacion.
final class QuickAccessController: QuickAccessPresenting {
    private let settings: AppSettings
    private var cards: [QuickAccessCard] = []

    private let cardSize = CGSize(width: 248, height: 160)
    private let spacing: CGFloat = 12
    private let margin: CGFloat = 16
    private let maxCards = 5

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show(_ item: CaptureItem, actions: QuickAccessActions) {
        let card = QuickAccessCard(item: item, size: cardSize)
        card.onClose = { [weak self] in self?.dismiss(itemID: item.id) }
        card.onHoverChanged = { [weak self, weak card] hovering in
            guard let card else { return }
            if hovering {
                card.cancelAutoClose()
            } else {
                self?.scheduleAutoClose(for: card)
            }
        }
        card.onDragEnded = { [weak self] success in
            guard success, self?.settings.quickAccessClosesAfterDrag == true else { return }
            self?.dismiss(itemID: item.id)
        }
        card.configure(actions: actions)

        cards.insert(card, at: 0)
        while cards.count > maxCards, let oldest = cards.popLast() {
            oldest.close(animated: false)
        }

        layout(animated: true, presenting: card)
        scheduleAutoClose(for: card)
    }

    func dismiss(itemID: UUID) {
        guard let index = cards.firstIndex(where: { $0.item.id == itemID }) else { return }
        let card = cards.remove(at: index)
        card.close(animated: true, towards: settings.quickAccessPosition)
        layout(animated: true, presenting: nil)
    }

    private func scheduleAutoClose(for card: QuickAccessCard) {
        let delay = settings.quickAccessAutoClose
        guard delay > 0 else { return }
        card.scheduleAutoClose(after: TimeInterval(delay)) { [weak self] in
            self?.dismiss(itemID: card.item.id)
        }
    }

    private func layout(animated: Bool, presenting newCard: QuickAccessCard?) {
        let screen = ScreenGeometry.screenUnderCursor
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let position = settings.quickAccessPosition

        for (index, card) in cards.enumerated() {
            let x = position == .bottomRight ? visible.maxX - cardSize.width - margin : visible.minX + margin
            let y = visible.minY + margin + CGFloat(index) * (cardSize.height + spacing)
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: cardSize)

            if card === newCard {
                card.present(at: frame, from: position)
            } else {
                card.move(to: frame, animated: animated)
            }
        }
    }
}

// MARK: - Card

private final class QuickAccessCard {
    let item: CaptureItem
    var onClose: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragEnded: ((Bool) -> Void)?

    private let panel: NSPanel
    private let hosting: FirstMouseHostingView<QuickAccessCardView>
    private var autoCloseTask: Task<Void, Never>?

    init(item: CaptureItem, size: CGSize) {
        self.item = item

        hosting = FirstMouseHostingView(rootView: QuickAccessCardView(item: item, size: size, actions: nil))
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
    }

    func configure(actions: QuickAccessActions) {
        let wrapped = QuickAccessCardView.Actions(
            copy: actions.onCopy,
            save: actions.onSave,
            edit: { [weak self] in
                actions.onEdit()
                self?.onClose?()
            },
            pin: actions.onPin.map { pin in
                { [weak self] in
                    pin()
                    self?.onClose?()
                }
            },
            close: { [weak self] in self?.onClose?() },
            hoverChanged: { [weak self] in self?.onHoverChanged?($0) },
            dragEnded: { [weak self] in self?.onDragEnded?($0) }
        )
        hosting.rootView = QuickAccessCardView(item: item, size: hosting.rootView.size, actions: wrapped)
    }

    func present(at frame: CGRect, from position: QuickAccessPosition) {
        let offset: CGFloat = position == .bottomRight ? frame.width + 40 : -(frame.width + 40)
        panel.setFrame(frame.offsetBy(dx: offset, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func move(to frame: CGRect, animated: Bool) {
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().setFrame(frame, display: true)
        }
    }

    func close(animated: Bool, towards position: QuickAccessPosition = .bottomRight) {
        cancelAutoClose()
        guard animated else {
            panel.orderOut(nil)
            return
        }

        let offset: CGFloat = position == .bottomRight ? panel.frame.width + 40 : -(panel.frame.width + 40)
        let target = panel.frame.offsetBy(dx: offset, dy: 0)
        let panel = panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    func scheduleAutoClose(after delay: TimeInterval, action: @escaping () -> Void) {
        autoCloseTask?.cancel()
        autoCloseTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancelAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
    }
}

// MARK: - Card view

private struct QuickAccessCardView: View {
    struct Actions {
        let copy: () -> Void
        let save: () -> Void
        let edit: () -> Void
        let pin: (() -> Void)?
        let close: () -> Void
        let hoverChanged: (Bool) -> Void
        let dragEnded: (Bool) -> Void
    }

    let item: CaptureItem
    let size: CGSize
    let actions: Actions?

    @State private var isHovering = false
    @State private var duration: TimeInterval?

    var body: some View {
        ZStack {
            Image(nsImage: item.thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()

            FileDragSource(
                fileURL: { item.fileURL },
                previewImage: item.thumbnail,
                onClick: { actions?.edit() },
                onDragEnded: { actions?.dragEnded($0) },
                onSwipe: { actions?.close() }
            )

            if isHovering {
                hoverOverlay
                    .transition(.opacity)
            }

            if !isHovering {
                mediaBadge
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
            actions?.hoverChanged(hovering)
        }
        .task {
            if let url = item.videoURL {
                duration = await VideoExporter.duration(of: url)
            }
        }
    }

    private var hoverOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .allowsHitTesting(false)

            VStack(spacing: 8) {
                pillButton("Copiar", action: { actions?.copy() })
                pillButton("Guardar", action: { actions?.save() })
            }

            VStack {
                HStack {
                    circleButton("xmark", help: "Cerrar") { actions?.close() }
                    Spacer()
                    if let pin = actions?.pin {
                        circleButton("pin", help: "Fijar en pantalla", action: pin)
                    }
                    circleButton(item.isImage ? "pencil" : "scissors", help: item.isImage ? "Anotar" : "Recortar video") {
                        actions?.edit()
                    }
                }
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var mediaBadge: some View {
        switch item.content {
        case .image:
            EmptyView()
        case .video, .gif:
            VStack {
                Spacer()
                HStack {
                    Label(badgeText, systemImage: item.videoURL != nil ? "play.fill" : "photo.stack")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.6), in: Capsule())
                    Spacer()
                }
            }
            .padding(8)
            .allowsHitTesting(false)
        }
    }

    private var badgeText: String {
        guard item.videoURL != nil else { return "GIF" }
        guard let duration else { return "Video" }
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 108, height: 30)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func circleButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
