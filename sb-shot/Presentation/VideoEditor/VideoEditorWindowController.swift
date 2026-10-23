import AppKit
import AVKit
import Combine
import SwiftUI

/// Reproduce una grabacion y permite recortarla, quitarle el audio y exportarla a MP4 o GIF.
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let model: VideoEditorModel

    init(videoURL: URL, actions: VideoEditorActions) {
        model = VideoEditorModel(videoURL: videoURL, actions: actions)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Editar grabación"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(EditorColors.windowBackground)
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.contentView = NSHostingView(rootView: VideoEditorView(model: model))
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        model.player.pause()
        onClose?()
    }
}

@MainActor
private final class VideoEditorModel: ObservableObject {
    let videoURL: URL
    let player: AVPlayer
    let actions: VideoEditorActions
    weak var playerView: AVPlayerView?

    @Published var removeAudio = false
    @Published var isExporting = false
    @Published var trimDescription: String?

    init(videoURL: URL, actions: VideoEditorActions) {
        self.videoURL = videoURL
        self.actions = actions
        player = AVPlayer(url: videoURL)
    }

    var trimRange: CMTimeRange? {
        guard let item = player.currentItem else { return nil }
        let duration = item.duration
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration

        guard duration.isValid, start != .zero || end != duration else { return nil }
        return CMTimeRange(start: start, end: end)
    }

    func beginTrimming() {
        guard let playerView, playerView.canBeginTrimming else { return }
        playerView.beginTrimming { _ in
            Task { @MainActor [weak self] in self?.updateTrimDescription() }
        }
    }

    func copy() {
        export { [actions] url in actions.onCopy(url) }
    }

    func save() {
        export { [actions] url in actions.onSave(url) }
    }

    func exportGIF() {
        let range = trimRange.map { CMTimeRangeValue(start: $0.start.seconds, duration: $0.duration.seconds) }
        actions.onExportGIF(videoURL, range)
    }

    private func export(_ completion: @escaping (URL) -> Void) {
        let range = trimRange
        guard range != nil || removeAudio else {
            completion(videoURL)
            return
        }

        isExporting = true
        let output = videoURL.deletingLastPathComponent()
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + "-editado")
            .appendingPathExtension("mp4")

        Task {
            defer { isExporting = false }
            do {
                let url = try await VideoExporter.export(videoURL: videoURL, to: output, timeRange: range, removeAudio: removeAudio)
                completion(url)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func updateTrimDescription() {
        guard let range = trimRange else {
            trimDescription = nil
            return
        }
        trimDescription = "Recorte: \(Self.format(range.start.seconds)) – \(Self.format(range.end.seconds))"
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: 28)

            PlayerViewRepresentable(model: model)
                .background(Color.black)

            Divider().overlay(EditorColors.groupBorder)

            HStack(spacing: 8) {
                Button {
                    model.beginTrimming()
                } label: {
                    Label("Recortar", systemImage: "scissors")
                }
                .buttonStyle(ActionButtonStyle(isPrimary: false))
                .help("Recortar el inicio y el final")

                Toggle(isOn: $model.removeAudio) {
                    Label("Quitar audio", systemImage: "speaker.slash")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.button)
                .buttonStyle(ActionButtonStyle(isPrimary: false, isActive: model.removeAudio))

                if let trimDescription = model.trimDescription {
                    Text(trimDescription)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if model.isExporting {
                    ProgressView().controlSize(.small)
                }

                Button("Exportar GIF", action: model.exportGIF)
                    .buttonStyle(ActionButtonStyle(isPrimary: false))

                Button("Guardar", action: model.save)
                    .buttonStyle(ActionButtonStyle(isPrimary: false))

                Button(action: model.copy) {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
                .buttonStyle(ActionButtonStyle())
            }
            .disabled(model.isExporting)
            .padding(.horizontal, 12)
            .frame(height: 48)
        }
        .background(EditorColors.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let model: VideoEditorModel

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = model.player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        model.playerView = view
        return view
    }

    func updateNSView(_: AVPlayerView, context _: Context) {}
}
