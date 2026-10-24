#if DEBUG
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// DEBUG-only demo mode that stages one window with synthetic content, captures it with ScreenCaptureKit,
/// writes a PNG and quits. Used to produce the README screenshots.
///
/// Launch: `SbShot -SbShotDemo <scene> [-SbShotDemoOutput <dir>] [-SbShotDemoSettingsTab <tab>]`.
/// Scenes: hero, editor, video-editor, quick-access, history, settings, pin.
/// The default output folder is `<container tmp>/sb-shot-demo-output`; the absolute path of the PNG is printed.
/// Settings, files and history use isolated temporary stores: the user's data is never read or modified.
@MainActor
enum DemoMode {
    enum Scene: String, CaseIterable {
        case hero
        case editor
        case videoEditor = "video-editor"
        case quickAccess = "quick-access"
        case history
        case settings
        case pin
    }

    static let scene: Scene? = UserDefaults.standard.string(forKey: "SbShotDemo").flatMap(Scene.init(rawValue:))

    static var isActive: Bool {
        scene != nil
    }

    /// Volatile defaults with factory values, so the demo shows default settings.
    static let defaults: UserDefaults? = {
        guard isActive else { return nil }
        let name = "com.burgos.sb-shot.demo"
        UserDefaults().removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)
    }()

    /// Scratch folder recreated on every demo launch.
    private static let workDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sb-shot-demo", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Subfolder of the demo scratch folder, or `nil` outside demo mode (the caller then uses its default).
    static func directory(_ name: String) -> URL? {
        guard isActive else { return nil }
        let url = workDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var outputDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "SbShotDemoOutput") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("sb-shot-demo-output", isDirectory: true)
    }

    /// Objects that must stay alive while their windows are captured.
    private static var retained: [AnyObject] = []

    static func startIfRequested() {
        guard let scene else { return }

        // Never hang: quit with an error if the scene doesn't finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            log("Timed out")
            exit(3)
        }

        Task {
            do {
                if let wallpaper = DemoSamples.wallpaper() {
                    WallpaperProvider.shared.demoImage = wallpaper
                    await WallpaperProvider.shared.refresh()
                }
                let image = try await run(scene)
                let url = try write(image, name: scene.rawValue)
                log("Wrote \(url.path)")
                NSApp.terminate(nil)
            } catch {
                log("Failed: \(error)")
                exit(2)
            }
        }
    }

    // MARK: - Scenes

    private static func run(_ scene: Scene) async throws -> CGImage {
        switch scene {
        case .hero: try await hero()
        case .editor: try await editor()
        case .videoEditor: try await videoEditor()
        case .quickAccess: try await quickAccess()
        case .history: try await history()
        case .settings: try await settings()
        case .pin: try await pin()
        }
    }

    /// The editor's own export of the annotated sample, with background.
    private static func hero() async throws -> CGImage {
        let model = CaptureEditorViewModel(baseImage: DemoSamples.dashboard())
        var (document, _) = DemoSamples.annotatedDocument()
        document.background = heroBackground
        model.loadDemoDocument(document, selecting: nil)
        // Lets the background blur variant finish before rendering.
        try await Task.sleep(nanoseconds: 500_000_000)
        let image = await model.renderImage()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DemoError.render }
        return cgImage
    }

    private static var heroBackground: BackgroundSettings {
        var background = BackgroundSettings()
        background.isEnabled = true
        background.presetIndex = 0
        background.padding = 80
        background.cornerRadius = 14
        background.shadow = true
        return background
    }

    private static func editor() async throws -> CGImage {
        let controller = CaptureEditorWindowController(image: DemoSamples.dashboard(), actions: EditorActions(
            onCopy: { _ in }, onSave: { _ in }, onSaveAs: { _ in }, onPin: { _ in }
        ))
        retained.append(controller)
        controller.show()
        var (document, selectedID) = DemoSamples.annotatedDocument()
        document.background = heroBackground
        document.background.padding = 56
        controller.demoViewModel.loadDemoDocument(document, selecting: selectedID)

        let window = try require(controller.window)
        ignoreMouse(window)
        place(window, size: CGSize(width: 1360, height: 860))
        try await settle(2.5)
        return try await capture(window)
    }

    private static func videoEditor() async throws -> CGImage {
        let videoURL = workDirectory.appendingPathComponent("demo-recording.mp4")
        try await DemoSamples.writeVideo(to: videoURL)

        let controller = VideoEditorWindowController(videoURL: videoURL, actions: VideoEditorActions(
            onCopy: { _ in }, onSave: { _ in }, defaultFormat: .mp4, gifFramesPerSecond: 15
        ))
        retained.append(controller)
        controller.show()
        let window = try require(controller.window)
        ignoreMouse(window)
        place(window, size: CGSize(width: 1360, height: 860))

        let model = controller.demoModel
        model.updateBackground {
            $0.isEnabled = true
            $0.presetIndex = 1
            $0.padding = 64
            $0.cornerRadius = 14
        }
        try await settle(1.5)
        model.seek(to: 3.1)
        try await settle(2)
        return try await capture(window)
    }

    private static func quickAccess() async throws -> CGImage {
        let videoURL = workDirectory.appendingPathComponent("demo-recording.mp4")
        try await DemoSamples.writeVideo(to: videoURL)
        let videoThumbnail = await VideoExporter.thumbnail(for: videoURL) ?? NSImage(size: CGSize(width: 16, height: 10))

        let hero = try await hero()
        let heroImage = NSImage(cgImage: hero, size: CGSize(width: hero.width / 2, height: hero.height / 2))
        let items = [
            CaptureItem(content: .image(DemoSamples.code()), thumbnail: DemoSamples.code(), fileURL: try writeSample(DemoSamples.code(), name: "code.png")),
            CaptureItem(content: .video(videoURL), thumbnail: videoThumbnail, fileURL: videoURL),
            CaptureItem(content: .image(heroImage), thumbnail: heroImage, fileURL: try writeSample(heroImage, name: "hero.png")),
        ]

        let settings = AppSettings(defaults: defaults ?? .standard)
        let controller = QuickAccessController(settings: settings)
        retained.append(controller)
        let windows = try await newWindows {
            for item in items {
                controller.show(item, actions: QuickAccessActions(fileURL: { item.fileURL }, onCopy: {}, onSave: {}, onEdit: {}, onPin: nil))
            }
        }
        try await settle(1)

        // Move the stack to the bottom-right corner of the Retina screen, keeping its layout.
        let screen = retinaScreen.visibleFrame
        let union = windows.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        for window in windows {
            window.setFrame(window.frame.offsetBy(dx: screen.maxX - 16 - union.maxX, dy: screen.minY + 16 - union.minY), display: true)
        }
        try await settle(0.6)
        return try await captureOnWallpaper(windows, margins: NSEdgeInsets(top: 48, left: 160, bottom: 48, right: 48))
    }

    private static func history() async throws -> CGImage {
        let directory = workDirectory.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let videoURL = workDirectory.appendingPathComponent("demo-recording.mp4")
        try await DemoSamples.writeVideo(to: videoURL)
        let dashboard = DemoSamples.dashboard()
        let tasks = DemoSamples.tasks()
        let code = DemoSamples.code()
        let hero = try await hero()

        // Newest first, with varied dates.
        let samples: [(source: Any, ext: String, kind: HistoryEntry.Kind, minutesAgo: Double)] = [
            (NSImage(cgImage: hero, size: CGSize(width: hero.width, height: hero.height)), "png", .image, 4),
            (dashboard, "png", .image, 18),
            (videoURL, "mp4", .video, 52),
            (code, "png", .image, 140),
            (DemoSamples.crop(tasks, to: CGRect(x: 0, y: 0, width: 560, height: 420)), "gif", .gif, 60 * 5),
            (tasks, "png", .image, 60 * 26),
            (DemoSamples.crop(dashboard, to: CGRect(x: 240, y: 260, width: 600, height: 300)), "png", .image, 60 * 30),
            (DemoSamples.crop(code, to: CGRect(x: 200, y: 36, width: 560, height: 380)), "png", .image, 60 * 52),
        ]
        var entries: [HistoryEntry] = []
        for sample in samples {
            let id = UUID()
            let fileName = "\(id.uuidString).\(sample.ext)"
            let url = directory.appendingPathComponent(fileName)
            if let image = sample.source as? NSImage {
                try writeImage(image, to: url, type: sample.ext == "gif" ? .gif : .png)
            } else if let source = sample.source as? URL {
                try FileManager.default.copyItem(at: source, to: url)
            }
            entries.append(HistoryEntry(id: id, fileName: fileName, kind: sample.kind, createdAt: Date().addingTimeInterval(-sample.minutesAgo * 60)))
        }
        try JSONEncoder().encode(entries).write(to: directory.appendingPathComponent("index.json"))

        let store = HistoryStore(directory: directory)
        let presenter = HistoryWindowPresenter(store: store, actions: HistoryActions(open: { _, _ in }, copy: { _, _ in }, reveal: { _ in }))
        retained.append(store)
        retained.append(presenter)
        let windows = try await newWindows { presenter.show() }
        let window = try require(windows.first)
        place(window, size: CGSize(width: 900, height: 470))
        try await settle(2)
        return try await capture(window)
    }

    private static func settings() async throws -> CGImage {
        let windows = try await newWindows {
            if !openSettingsWindow() {
                log("Couldn’t find the Settings command")
            }
        }
        let window = try require(windows.first)

        let tab = UserDefaults.standard.string(forKey: "SbShotDemoSettingsTab") ?? "Shortcuts"
        if let item = window.toolbar?.items.first(where: { $0.label == tab }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else {
            log("Settings tab not found: \(tab); available: \(window.toolbar?.items.map(\.label) ?? [])")
        }
        try await settle(0.8)
        place(window, size: window.frame.size)
        try await settle(1)
        return try await capture(window)
    }

    private static func pin() async throws -> CGImage {
        let presenter = PinnedImagePresenter(toast: ToastController())
        retained.append(presenter)
        let windows = try await newWindows {
            presenter.pin(image: DemoSamples.code(), onEdit: { _ in }, onCopy: { _ in })
        }
        let window = try require(windows.first)
        place(window, size: window.frame.size)
        try await settle(0.8)
        return try await captureOnWallpaper([window], margins: NSEdgeInsets(top: 64, left: 64, bottom: 64, right: 64))
    }

    // MARK: - Windows

    /// Screen with the highest scale factor, so captures are Retina.
    private static var retinaScreen: NSScreen {
        NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The real pointer may be over the staged windows: hover effects would show up in the capture.
    private static func ignoreMouse(_ window: NSWindow) {
        window.ignoresMouseEvents = true
    }

    /// Centers the window on the Retina screen with the given size (limited to the visible area).
    private static func place(_ window: NSWindow, size: CGSize) {
        let visible = retinaScreen.visibleFrame
        let width = min(size.width, visible.width - 40)
        let height = min(size.height, visible.height - 40)
        window.setFrame(CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height).integral, display: true)
        // Captured windows should look active.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Runs `action` and returns the visible windows it opened.
    private static func newWindows(_ action: () -> Void) async throws -> [NSWindow] {
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        action()
        for _ in 0 ..< 30 {
            try await settle(0.1)
            let opened = NSApp.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
            if !opened.isEmpty {
                try await settle(0.3)
                let windows = NSApp.windows.filter { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
                windows.forEach(ignoreMouse)
                return windows
            }
        }
        throw DemoError.windowNotFound
    }

    /// SwiftUI adds a "Settings…" (⌘,) item to the app menu; the selector works as a fallback.
    private static func openSettingsWindow() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        func find(in menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command, item.action != nil {
                    return item
                }
                if let found = find(in: item.submenu) {
                    return found
                }
            }
            return nil
        }
        if let item = find(in: NSApp.mainMenu), let action = item.action, NSApp.sendAction(action, to: item.target, from: item) {
            return true
        }
        return NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private static func settle(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw DemoError.windowNotFound }
        return value
    }

    // MARK: - Capture

    /// Margin around the window so ScreenCaptureKit keeps the whole shadow (see `ScreenCaptureService`).
    private static let shadowMargin: CGFloat = 100

    /// Captures a window with its shadow, trimmed to the visible pixels.
    private static func capture(_ window: NSWindow) async throws -> CGImage {
        let image = try await captureUntrimmed(window).image
        return await ScreenCaptureService.trimmingTransparentEdges(image) ?? image
    }

    /// Captures a window centered on a canvas `shadowMargin` points larger on each side.
    private static func captureUntrimmed(_ window: NSWindow) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw DemoError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(((filter.contentRect.width + shadowMargin * 2) * scale).rounded())
        config.height = Int(((filter.contentRect.height + shadowMargin * 2) * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = false
        config.shouldBeOpaque = false
        config.backgroundColor = .clear
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Captures floating windows and places them over the synthetic wallpaper, keeping their layout.
    private static func captureOnWallpaper(_ windows: [NSWindow], margins: NSEdgeInsets) async throws -> CGImage {
        // Each capture is trimmed and centered on its window frame, at the canvas scale.
        let scale: CGFloat = 2
        var shots: [(image: CGImage, frame: CGRect, imageScale: CGFloat)] = []
        for window in windows {
            let shot = try await captureUntrimmed(window)
            let trimmed = await ScreenCaptureService.trimmingTransparentEdges(shot.image) ?? shot.image
            shots.append((trimmed, window.frame, shot.scale))
        }

        let union = shots.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let canvas = CGRect(
            x: union.minX - margins.left,
            y: union.minY - margins.bottom,
            width: union.width + margins.left + margins.right,
            height: union.height + margins.top + margins.bottom
        )
        let width = Int(canvas.width * scale)
        let height = Int(canvas.height * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let wallpaper = DemoSamples.wallpaper()
        else { throw DemoError.render }

        context.interpolationQuality = .high
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(wallpaper, in: .aspectFill(CGSize(width: wallpaper.width, height: wallpaper.height), in: bounds))
        // AppKit and an unflipped CGContext both use a bottom-left origin.
        for shot in shots {
            let size = CGSize(width: CGFloat(shot.image.width) / shot.imageScale * scale, height: CGFloat(shot.image.height) / shot.imageScale * scale)
            let center = CGPoint(x: (shot.frame.midX - canvas.minX) * scale, y: (shot.frame.midY - canvas.minY) * scale)
            // The shadow is deeper below the window, so the trimmed image's center sits slightly lower.
            let shadowDrop = 8 * scale
            context.draw(shot.image, in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2 - shadowDrop, width: size.width, height: size.height))
        }
        guard let image = context.makeImage() else { throw DemoError.render }
        return image
    }

    // MARK: - Files

    private static let maxOutputWidth = 2400

    /// Writes the PNG, downscaled to `maxOutputWidth` if wider.
    private static func write(_ image: CGImage, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try writeCGImage(downscaled(image, maxWidth: maxOutputWidth), to: url, type: .png)
        return url
    }

    private static func downscaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let width = maxWidth
        let height = Int((CGFloat(image.height) * CGFloat(maxWidth) / CGFloat(image.width)).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func writeSample(_ image: NSImage, name: String) throws -> URL {
        let url = workDirectory.appendingPathComponent(name)
        try writeImage(image, to: url, type: .png)
        return url
    }

    private static func writeImage(_ image: NSImage, to url: URL, type: UTType) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DemoError.render }
        try writeCGImage(cgImage, to: url, type: type)
    }

    private static func writeCGImage(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw DemoError.write
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DemoError.write }
    }

    private static func log(_ message: String) {
        print("[SbShotDemo] \(message)")
        fflush(stdout)
    }

    private enum DemoError: Error {
        case windowNotFound
        case render
        case write
    }
}
#endif
