import AppKit
import Combine
import SwiftUI

/// Floating bar with the recording time and controls, plus a border around the recorded area.
/// Neither window appears in the video.
final class RecordingControlsController: RecordingControlsPresenting {
    private final class Model: ObservableObject {
        @Published var elapsed: TimeInterval = 0
    }

    private var controlsPanel: NSPanel?
    private var borderWindow: NSWindow?
    private let model = Model()

    func show(
        for selection: ScreenSelection,
        onStop: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        hide()
        model.elapsed = 0

        if case let .area(rect) = selection {
            borderWindow = makeBorderWindow(around: rect)
        }

        let view = RecordingControlsView(model: model, onStop: onStop, onRestart: onRestart, onCancel: onCancel)
        let hosting = FirstMouseHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        panel.setFrameOrigin(Self.controlsOrigin(for: selection.frame, size: size))
        panel.orderFrontRegardless()
        controlsPanel = panel
    }

    func update(elapsed: TimeInterval) {
        model.elapsed = elapsed
    }

    func hide() {
        controlsPanel?.orderOut(nil)
        controlsPanel = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }

    private func makeBorderWindow(around rect: CGRect) -> NSWindow {
        let inset: CGFloat = 4
        let frame = rect.insetBy(dx: -inset, dy: -inset)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: RecordingBorderView(inset: inset))
        window.setFrame(frame, display: false)
        window.orderFrontRegardless()
        return window
    }

    private static func controlsOrigin(for rect: CGRect, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? rect
        let x = min(max(rect.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)

        let below = rect.minY - size.height - 14
        if below >= visible.minY + 8 {
            return CGPoint(x: x, y: below)
        }
        let above = rect.maxY + 14
        if above + size.height <= visible.maxY - 8 {
            return CGPoint(x: x, y: above)
        }
        return CGPoint(x: x, y: visible.minY + 24)
    }

    // MARK: - Views

    private struct RecordingControlsView: View {
        @ObservedObject var model: Model
        let onStop: () -> Void
        let onRestart: () -> Void
        let onCancel: () -> Void

        @State private var pulse = false

        var body: some View {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .padding(.leading, 6)

                Text(Self.format(model.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 52, alignment: .leading)

                Divider()
                    .frame(height: 18)
                    .overlay(Color.white.opacity(0.2))

                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.red.opacity(0.85), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop and save")

                iconButton("arrow.counterclockwise", help: "Restart recording", action: onRestart)
                iconButton("trash", help: "Discard recording", action: onCancel)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .environment(\.colorScheme, .dark)
            .padding(10)
            .onAppear { pulse = true }
        }

        private func iconButton(_ systemName: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }

        static func format(_ interval: TimeInterval) -> String {
            let total = Int(interval)
            return String(format: "%02d:%02d", total / 60, total % 60)
        }
    }

    private struct RecordingBorderView: View {
        let inset: CGFloat

        var body: some View {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(Color.white.opacity(0.9))
                .shadow(color: .black.opacity(0.6), radius: 1)
                .padding(inset / 2 - 1)
        }
    }
}
