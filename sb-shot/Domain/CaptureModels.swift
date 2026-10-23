import AppKit

// MARK: - Actions

enum CaptureAction: String, CaseIterable, Codable, Identifiable {
    case captureArea
    case capturePreviousArea
    case captureFullscreen
    case captureWindow
    case captureText
    case recordArea
    case recordFullscreen
    case openHistory

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .captureArea: "Capturar área o ventana"
        case .capturePreviousArea: "Capturar área anterior"
        case .captureFullscreen: "Capturar pantalla completa"
        case .captureWindow: "Capturar ventana"
        case .captureText: "Capturar texto (OCR)"
        case .recordArea: "Grabar área o ventana"
        case .recordFullscreen: "Grabar pantalla completa"
        case .openHistory: "Abrir historial"
        }
    }

    var iconName: String {
        switch self {
        case .captureArea: "rectangle.dashed"
        case .capturePreviousArea: "arrow.counterclockwise.circle"
        case .captureFullscreen: "macwindow.on.rectangle"
        case .captureWindow: "macwindow"
        case .captureText: "text.viewfinder"
        case .recordArea: "record.circle"
        case .recordFullscreen: "display"
        case .openHistory: "clock.arrow.circlepath"
        }
    }

    var defaultShortcut: GlobalShortcut? {
        let commandShift: NSEvent.ModifierFlags = [.command, .shift]
        let commandShiftOption: NSEvent.ModifierFlags = [.command, .shift, .option]

        switch self {
        case .captureArea: return GlobalShortcut(keyCode: 19, modifiers: commandShift)
        case .capturePreviousArea: return GlobalShortcut(keyCode: 19, modifiers: commandShiftOption)
        case .captureFullscreen: return GlobalShortcut(keyCode: 18, modifiers: commandShift)
        case .captureWindow: return GlobalShortcut(keyCode: 26, modifiers: commandShift)
        case .captureText: return GlobalShortcut(keyCode: 28, modifiers: commandShift)
        case .recordArea: return GlobalShortcut(keyCode: 25, modifiers: commandShift)
        case .recordFullscreen: return GlobalShortcut(keyCode: 25, modifiers: commandShiftOption)
        case .openHistory: return GlobalShortcut(keyCode: 29, modifiers: commandShift)
        }
    }
}

// MARK: - Shortcuts

struct GlobalShortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiersRawValue: UInt

    init(keyCode: UInt32, modifiersRawValue: UInt) {
        self.keyCode = keyCode
        self.modifiersRawValue = modifiersRawValue
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, modifiersRawValue: modifiers.rawValue)
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue)
    }
}

// MARK: - Selection

/// Resultado de una seleccion en pantalla. Las coordenadas son globales de AppKit (origen abajo-izquierda).
enum ScreenSelection: Equatable {
    case area(CGRect)
    case window(id: CGWindowID, frame: CGRect)
    case display(id: CGDirectDisplayID, frame: CGRect)

    var frame: CGRect {
        switch self {
        case let .area(rect): rect
        case let .window(_, frame): frame
        case let .display(_, frame): frame
        }
    }
}

enum SelectionPurpose {
    case screenshot
    case recording
    case text
}

nonisolated struct SelectionOptions {
    var purpose: SelectionPurpose = .screenshot
    var startInWindowMode = false
    var allowsWindowMode = true
    var freezeScreen = false
    var showsMagnifier = true
    var showsCrosshair = true
    /// Oculta los iconos del escritorio en la imagen congelada (`freezeScreen`).
    var hidesDesktopIcons = false
}

struct SelectionResult {
    let selection: ScreenSelection
    /// Imagen ya recortada de la pantalla congelada, si la seleccion se hizo sobre una captura fija.
    let frozenImage: NSImage?
}

// MARK: - Capture

enum ScreenshotMode: Equatable {
    case area
    case previousArea
    case fullscreen
    case window
    case timed(seconds: Int)
}

nonisolated struct CaptureOptions {
    var includeWindowShadow = true
    var hideDesktopIcons = false
    var downscaleToOneX = false
}

enum ImageFileFormat: String, CaseIterable, Codable, Identifiable {
    case png
    case jpeg

    var id: String {
        rawValue
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }
}

// MARK: - Recording

enum RecordingFormat: String, CaseIterable, Codable, Identifiable {
    case mp4
    case gif

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .mp4: "Video (MP4)"
        case .gif: "GIF animado"
        }
    }
}

struct RecordingOptions {
    var format: RecordingFormat = .mp4
    var framesPerSecond = 60
    var showsCursor = true
    var highlightsClicks = false
    var capturesSystemAudio = false
    var capturesMicrophone = false
    var countdownSeconds = 3
    var retinaQuality = true
    var gifFramesPerSecond = 15
    var gifMaxWidth: CGFloat = 960
}

// MARK: - Results

struct CaptureItem: Identifiable {
    enum Content {
        case image(NSImage)
        case video(URL)
        case gif(URL)
    }

    let id = UUID()
    var content: Content
    var thumbnail: NSImage
    /// Archivo en disco listo para arrastrar, copiar o mover.
    var fileURL: URL
    let createdAt = Date()

    var isImage: Bool {
        if case .image = content {
            return true
        }
        return false
    }

    var image: NSImage? {
        if case let .image(image) = content {
            return image
        }
        return nil
    }

    var videoURL: URL? {
        if case let .video(url) = content {
            return url
        }
        return nil
    }
}

enum QuickAccessPosition: String, CaseIterable, Codable, Identifiable {
    case bottomLeft
    case bottomRight

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .bottomLeft: "Abajo a la izquierda"
        case .bottomRight: "Abajo a la derecha"
        }
    }
}
