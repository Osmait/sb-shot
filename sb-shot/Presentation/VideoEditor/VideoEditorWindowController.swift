import AppKit
import AVKit
import Combine
import SwiftUI

/// Recorta una grabacion con una barra de fotogramas y la exporta a MP4 o GIF desde un panel lateral.
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let model: VideoEditorModel
    private var keyMonitor: Any?

    init(videoURL: URL, actions: VideoEditorActions) {
        model = VideoEditorModel(videoURL: videoURL, actions: actions)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Editar grabación"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(EditorColors.windowBackground)
        window.minSize = NSSize(width: 900, height: 560)
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
        installKeyMonitor()
    }

    func windowWillClose(_: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        model.tearDown()
        onClose?()
    }

    /// Espacio reproduce o pausa; I y O fijan el inicio y el fin en la posicion actual.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window, event.window === window, !(window.firstResponder is NSTextView) else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.subtracting(.shift).isEmpty else { return event }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case " ": model.togglePlayback()
            case "i": model.setTrimStart(model.currentTime)
            case "o": model.setTrimEnd(model.currentTime)
            default: return event
            }
            return nil
        }
    }
}

// MARK: - Model

enum VideoQuality: CaseIterable {
    case small
    case medium
    case original

    func title(for format: RecordingFormat) -> String {
        switch (format, self) {
        case (.mp4, .small): "720p"
        case (.mp4, .medium): "1080p"
        case (.mp4, .original): "Original"
        case (.gif, .small): "480 px"
        case (.gif, .medium): "720 px"
        case (.gif, .original): "960 px"
        }
    }

    var maxVideoHeight: CGFloat? {
        switch self {
        case .small: 720
        case .medium: 1080
        case .original: nil
        }
    }

    var gifWidth: CGFloat {
        switch self {
        case .small: 480
        case .medium: 720
        case .original: 960
        }
    }
}

/// Tiempo de reproduccion aparte del modelo: cambia ~30 veces por segundo y solo lo observan el cabezal y el contador.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

@MainActor
final class VideoEditorModel: ObservableObject {
    let videoURL: URL
    let player: AVPlayer
    let actions: VideoEditorActions
    let clock = PlaybackClock()

    @Published private(set) var duration: Double = 0
    @Published private(set) var trimStart: Double = 0
    @Published private(set) var trimEnd: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [NSImage] = []
    @Published private(set) var hasAudio = false
    @Published private(set) var isExporting = false

    @Published var format: RecordingFormat {
        didSet {
            guard format != oldValue else { return }
            quality = format == .gif ? .medium : .original
            framesPerSecond = format == .gif ? actions.gifFramesPerSecond : min(sourceFPS, 60)
        }
    }

    @Published var quality: VideoQuality = .original
    @Published var framesPerSecond = 60
    @Published var includeAudio = true
    @Published var background = BackgroundSettings() {
        didSet {
            if background != oldValue {
                scheduleBackgroundPreview()
            }
        }
    }

    private var sourceFPS = 60
    private var sourcePixelHeight: CGFloat = 0
    private var fileSize: Int64 = 0
    private var timeObserver: Any?
    private var previewTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    static let minimumLength = 0.3

    init(videoURL: URL, actions: VideoEditorActions) {
        self.videoURL = videoURL
        self.actions = actions
        player = AVPlayer(url: videoURL)
        format = actions.defaultFormat
        if format == .gif {
            quality = .medium
            framesPerSecond = actions.gifFramesPerSecond
        }

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playerDidAdvance(to: time.seconds)
            }
        }

        Task { await load() }
    }

    var fpsOptions: [Int] {
        format == .gif ? [10, 15, 24] : [24, 30, 60]
    }

    var currentTime: Double {
        clock.time
    }

    var trimLength: Double {
        max(trimEnd - trimStart, 0)
    }

    var isTrimmed: Bool {
        trimStart > 0.05 || trimEnd < duration - 0.05
    }

    var estimatedSize: String {
        guard format == .mp4, duration > 0, fileSize > 0 else { return "Al exportar" }

        var bytes = Double(fileSize) * trimLength / duration
        if let maxHeight = quality.maxVideoHeight, sourcePixelHeight > maxHeight {
            bytes *= pow(maxHeight / sourcePixelHeight, 2)
        }
        bytes *= min(Double(framesPerSecond) / Double(max(sourceFPS, 1)), 1)
        return "≈ " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: Playback

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
            seek(to: trimStart)
        }
        player.play()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        clock.time = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Sin duracion cargada o con clips mas cortos que el minimo no hay recorte posible.
    func setTrimStart(_ seconds: Double) {
        guard duration >= Self.minimumLength else { return }
        trimStart = max(min(seconds, trimEnd - Self.minimumLength), 0)
        pauseAndSeek(to: trimStart)
    }

    func setTrimEnd(_ seconds: Double) {
        guard duration >= Self.minimumLength else { return }
        trimEnd = min(max(seconds, trimStart + Self.minimumLength), duration)
        pauseAndSeek(to: trimEnd)
    }

    func resetTrim() {
        trimStart = 0
        trimEnd = duration
    }

    func tearDown() {
        previewTask?.cancel()
        exportTask?.cancel()
        exportTask = nil
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: Background

    /// Estilo del fondo para Core Image, o `nil` si esta desactivado.
    var backgroundStyle: VideoBackgroundStyle? {
        guard background.isEnabled else { return nil }
        let colors = background.preset.colors.map(\.cgColorValue)
        return VideoBackgroundStyle(
            startColor: colors.first ?? CGColor(gray: 0, alpha: 1),
            endColor: colors.last ?? CGColor(gray: 0, alpha: 1),
            image: background.wallpaper.map { WallpaperBlur.image($0, radius: background.wallpaperBlur) },
            padding: background.padding,
            cornerRadius: background.cornerRadius,
            shadow: background.shadow,
            aspectRatio: background.aspect.ratio
        )
    }

    func updateBackground(_ change: (inout BackgroundSettings) -> Void) {
        var updated = background
        change(&updated)
        background = updated
    }

    /// Aplica el fondo a la reproduccion. Se agrupan los cambios seguidos de los sliders.
    private func scheduleBackgroundPreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, let item = player.currentItem else { return }

            // El estilo desenfoca el fondo de pantalla: se calcula tras la espera para no hacerlo en cada tick del slider.
            if let style = backgroundStyle {
                item.videoComposition = try? await VideoBackgroundCompositor.makeComposition(for: item.asset, style: style)
            } else {
                item.videoComposition = nil
            }
            guard !Task.isCancelled else { return }
            if !isPlaying {
                seek(to: currentTime)
            }
        }
    }

    // MARK: Export

    func copy() {
        export(actions.onCopy)
    }

    func save() {
        export(actions.onSave)
    }

    private func export(_ completion: @escaping (URL) -> Void) {
        let range = isTrimmed
            ? CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600), end: CMTime(seconds: trimEnd, preferredTimescale: 600))
            : nil

        let style = backgroundStyle
        let keepsOriginal = format == .mp4 && range == nil && style == nil && (includeAudio || !hasAudio)
            && quality == .original && framesPerSecond >= sourceFPS
        if keepsOriginal {
            completion(videoURL)
            return
        }

        player.pause()
        isPlaying = false
        isExporting = true

        // Cada exportacion va a su propia carpeta temporal: no pisa un archivo ya copiado o pegado
        // ni choca con otro editor de la misma grabacion, y conserva un nombre legible.
        let base = videoURL.deletingPathExtension().lastPathComponent
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-shot", isDirectory: true)
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        let output = folder
            .appendingPathComponent("\(base) recorte")
            .appendingPathExtension(format == .gif ? "gif" : "mp4")

        exportTask?.cancel()
        exportTask = Task { [weak self] in
            defer { self?.isExporting = false }
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url: URL = switch format {
                case .mp4:
                    try await VideoExporter.export(
                        videoURL: videoURL,
                        to: output,
                        timeRange: range,
                        removeAudio: !includeAudio,
                        maxHeight: quality.maxVideoHeight,
                        framesPerSecond: framesPerSecond,
                        background: style
                    )
                case .gif:
                    try await GifExporter.export(
                        videoURL: videoURL,
                        to: output,
                        framesPerSecond: framesPerSecond,
                        maxWidth: quality.gifWidth,
                        timeRange: range,
                        background: style
                    )
                }
                // Si la ventana se cerro durante la exportacion no se copia ni se guarda nada.
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: folder)
                    return
                }
                completion(url)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if !Task.isCancelled {
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: Private

    private func load() async {
        let asset = AVURLAsset(url: videoURL)
        let seconds = await (try? asset.load(.duration).seconds) ?? 0
        duration = seconds
        trimEnd = seconds

        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            sourceFPS = await Int(((try? track.load(.nominalFrameRate)) ?? 60).rounded())
            sourcePixelHeight = await (try? track.load(.naturalSize).height) ?? 0
            if format == .mp4 {
                framesPerSecond = min(max(sourceFPS, 24), 60)
            }
        }
        hasAudio = await !((try? asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
        fileSize = ((try? FileManager.default.attributesOfItem(atPath: videoURL.path)[.size]) as? NSNumber)?.int64Value ?? 0

        thumbnails = await VideoExporter.filmstrip(for: videoURL, count: 14, height: 48)
    }

    private func pauseAndSeek(to seconds: Double) {
        player.pause()
        isPlaying = false
        seek(to: seconds)
    }

    private func playerDidAdvance(to seconds: Double) {
        guard seconds.isFinite else { return }
        clock.time = seconds
        if isPlaying, seconds >= trimEnd {
            player.pause()
            isPlaying = false
            seek(to: trimEnd)
        }
    }

    static func timeString(_ seconds: Double) -> String {
        let clamped = max(seconds, 0)
        let minutes = Int(clamped) / 60
        let rest = clamped - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }

    /// Acepta "1:02.5", "62.5" o "62".
    static func parseTime(_ text: String) -> Double? {
        let parts = text.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }
}

// MARK: - Views

private struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                WindowDragArea()
                    .frame(height: 40)

                ZStack {
                    PlayerViewRepresentable(player: model.player)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: model.togglePlayback)
                    if !model.isPlaying {
                        Image(systemName: "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .padding(.horizontal, 32)

                VStack(spacing: 12) {
                    TrimBar(model: model)
                        .frame(height: 56)
                        .coordinateSpace(.named("trim"))
                    playbackRow
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 20)
            }
            .background(EditorColors.canvasBackground)

            Divider().overlay(EditorColors.groupBorder)

            ExportPanel(model: model)
                .frame(width: 300)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var playbackRow: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlayback) {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(EditorColors.chip, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Reproducir o pausar (Espacio)")

            TimeField(title: "Inicio", value: model.trimStart, onCommit: model.setTrimStart)
                .help("Fija el inicio en la posición actual con I")
            TimeField(title: "Fin", value: model.trimEnd, onCommit: model.setTrimEnd)
                .help("Fija el fin en la posición actual con O")

            if model.isTrimmed {
                Button("Restablecer", action: model.resetTrim)
                    .buttonStyle(ActionButtonStyle(isPrimary: false))
            }

            Spacer()

            PlaybackTimeLabel(clock: model.clock, duration: model.duration)
        }
    }
}

private struct PlaybackTimeLabel: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double

    var body: some View {
        Text("\(VideoEditorModel.timeString(clock.time)) / \(VideoEditorModel.timeString(duration))")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// Cabezal de la barra de recorte; es lo unico de la barra que se redibuja durante la reproduccion.
private struct Playhead: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let x = duration > 0 ? CGFloat(clock.time / duration) * width : 0
        Rectangle()
            .fill(Color.white)
            .frame(width: 2, height: height + 8)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .offset(x: x - 1, y: -4)
            .allowsHitTesting(false)
    }
}

/// Barra de recorte: tira de fotogramas, asas de inicio y fin, zona descartada oscurecida y cabezal.
private struct TrimBar: View {
    @ObservedObject var model: VideoEditorModel

    private let handleWidth: CGFloat = 14
    private let stripInset: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let startX = x(for: model.trimStart, width: width)
            let endX = x(for: model.trimEnd, width: width)

            ZStack(alignment: .topLeading) {
                filmstrip
                    .frame(width: width, height: height - stripInset * 2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .offset(y: stripInset)
                    .gesture(scrubGesture(width: width))

                Color.black.opacity(0.62)
                    .frame(width: max(startX, 0), height: height - stripInset * 2)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8))
                    .offset(y: stripInset)
                    .allowsHitTesting(false)

                Color.black.opacity(0.62)
                    .frame(width: max(width - endX, 0), height: height - stripInset * 2)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8))
                    .offset(x: endX, y: stripInset)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(endX - startX, handleWidth * 2), height: height)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                handle(height: height)
                    .offset(x: startX)
                    .gesture(handleGesture(width: width) { model.setTrimStart($0) })
                    .help("Arrastra para fijar el inicio")

                handle(height: height)
                    .offset(x: endX - handleWidth)
                    .gesture(handleGesture(width: width) { model.setTrimEnd($0) })
                    .help("Arrastra para fijar el fin")

                Playhead(clock: model.clock, duration: model.duration, width: width, height: height)
            }
        }
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                EditorColors.chip
            } else {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
        .background(EditorColors.chip)
    }

    private func handle(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: height)
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 18)
            )
            .contentShape(Rectangle().inset(by: -8))
            .pointerStyle(.columnResize)
    }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(seconds / model.duration) * width
    }

    private func seconds(for x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * model.duration
    }

    private func handleGesture(width: CGFloat, apply: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { value in apply(seconds(for: value.location.x, width: width)) }
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { value in model.seek(to: seconds(for: value.location.x, width: width)) }
    }
}

private struct TimeField: View {
    let title: String
    let value: Double
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.system(size: 12).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 64, height: 28)
                .background(EditorColors.inspectorBackground, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isFocused ? Color.accentColor : EditorColors.groupBorder, lineWidth: 1))
                .focused($isFocused)
                .onSubmit {
                    if let seconds = VideoEditorModel.parseTime(text) {
                        onCommit(seconds)
                    }
                    text = VideoEditorModel.timeString(value)
                    isFocused = false
                }
        }
        .onAppear { text = VideoEditorModel.timeString(value) }
        .onChange(of: value) { _, newValue in
            if !isFocused {
                text = VideoEditorModel.timeString(newValue)
            }
        }
    }
}

private struct ExportPanel: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Exportar")
                .font(.system(size: 15, weight: .bold))
                .padding(.top, 40)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    settingsSections
                    VideoBackgroundSection(model: model)
                }
            }
            .scrollIndicators(.never)

            footer
        }
        .padding(18)
        .frame(maxHeight: .infinity)
        .background(EditorColors.inspectorBackground)
    }

    @ViewBuilder
    private var settingsSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorTitle("Formato")
            HStack(spacing: 8) {
                formatCard(.mp4, title: "MP4", subtitle: "Video con audio")
                formatCard(.gif, title: "GIF", subtitle: "Animación sin audio")
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            InspectorTitle(model.format == .gif ? "Tamaño y fluidez" : "Calidad")
            ChipRow(options: VideoQuality.allCases, selection: $model.quality) { $0.title(for: model.format) }
            ChipRow(options: model.fpsOptions, selection: $model.framesPerSecond) { "\($0) fps" }
        }

        VStack(alignment: .leading, spacing: 10) {
            InspectorTitle("Audio")
            if model.format == .gif {
                Text("Los GIF no llevan audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if model.hasAudio {
                Toggle(isOn: $model.includeAudio) {
                    Text("Incluir audio").font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
            } else {
                Text("Esta grabación no tiene audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Text("Duración ").foregroundStyle(.secondary)
                + Text(String(format: "%.1f s", model.trimLength)).fontWeight(.semibold)
            Spacer()
            Text("Tamaño ").foregroundStyle(.secondary)
                + Text(model.estimatedSize).fontWeight(.semibold)
        }
        .font(.system(size: 12))
        .padding(12)
        .background(EditorColors.chip, in: RoundedRectangle(cornerRadius: 10))

        HStack(spacing: 8) {
            Button(action: model.save) {
                Text("Guardar").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false))

            Button(action: model.copy) {
                Group {
                    if model.isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Copiar")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle())
        }
        .disabled(model.isExporting)
    }

    private func formatCard(_ format: RecordingFormat, title: String, subtitle: String) -> some View {
        let isSelected = model.format == format
        return Button {
            model.format = format
        } label: {
            VStack(spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(isSelected ? EditorColors.chipSelected : EditorColors.chip, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : EditorColors.groupBorder, lineWidth: isSelected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Fondo del video: degradado o fondo de pantalla, margen, esquinas, sombra y proporcion, como en el editor de capturas.
private struct VideoBackgroundSection: View {
    @ObservedObject var model: VideoEditorModel

    private var background: BackgroundSettings {
        model.background
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                InspectorTitle("Fondo")
                Spacer()
                Toggle("Fondo", isOn: Binding(
                    get: { background.isEnabled },
                    set: { value in model.updateBackground { $0.isEnabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(BackgroundPreset.all) { preset in
                    Button {
                        model.updateBackground {
                            $0.presetIndex = preset.id
                            $0.wallpaper = nil
                            $0.isEnabled = true
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 34)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .opacity(background.isEnabled && background.wallpaper == nil && background.presetIndex == preset.id ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            WallpaperTile(isSelected: background.isEnabled && background.wallpaper != nil, height: 34) { image in
                model.updateBackground {
                    $0.wallpaper = image
                    $0.isEnabled = true
                }
            }

            if background.wallpaper != nil {
                InspectorSlider(title: "Desenfoque", value: binding(\.wallpaperBlur), range: 0 ... 40)
            }

            InspectorSlider(title: "Margen", value: binding(\.padding), range: 0 ... 200)
            InspectorSlider(title: "Esquinas", value: binding(\.cornerRadius), range: 0 ... 40)

            Toggle(isOn: Binding(
                get: { background.shadow },
                set: { value in model.updateBackground { $0.shadow = value } }
            )) {
                Text("Sombra").font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Text("Proporción")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ChipRow(
                    options: BackgroundAspect.allCases,
                    selection: Binding(
                        get: { background.aspect },
                        set: { value in
                            model.updateBackground {
                                $0.aspect = value
                                $0.isEnabled = true
                            }
                        }
                    )
                ) { $0.title }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<BackgroundSettings, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { background[keyPath: keyPath] },
            set: { value in
                model.updateBackground {
                    $0[keyPath: keyPath] = value
                    $0.isEnabled = true
                }
            }
        )
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_: AVPlayerView, context _: Context) {}
}
