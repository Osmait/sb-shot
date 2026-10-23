import SwiftUI

enum EditorTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case counter
    case pencil
    case highlighter
    case obfuscate
    case spotlight
    case crop

    var id: String {
        rawValue
    }

    var iconName: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .counter: "1.circle"
        case .pencil: "scribble"
        case .highlighter: "highlighter"
        case .obfuscate: "checkerboard.rectangle"
        case .spotlight: "flashlight.on.fill"
        case .crop: "crop"
        }
    }

    var title: String {
        switch self {
        case .select: "Seleccionar"
        case .arrow: "Flecha"
        case .line: "Línea"
        case .rectangle: "Rectángulo"
        case .ellipse: "Elipse"
        case .text: "Texto"
        case .counter: "Contador"
        case .pencil: "Lápiz"
        case .highlighter: "Resaltador"
        case .obfuscate: "Pixelar / desenfocar"
        case .spotlight: "Foco"
        case .crop: "Recortar"
        }
    }

    /// Tecla que activa la herramienta en el editor.
    var shortcutKey: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .counter: "n"
        case .pencil: "p"
        case .highlighter: "h"
        case .obfuscate: "b"
        case .spotlight: "s"
        case .crop: "c"
        }
    }

    var usesStrokeWidth: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .pencil, .highlighter, .counter: true
        case .select, .text, .obfuscate, .spotlight, .crop: false
        }
    }

    var usesColor: Bool {
        switch self {
        case .obfuscate, .spotlight, .crop: false
        default: true
        }
    }
}

enum ObfuscationMode: String, CaseIterable, Identifiable {
    case pixelate
    case blur

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .pixelate: "Pixelar"
        case .blur: "Desenfocar"
        }
    }
}

struct AnnotationStyle: Equatable {
    var color: Color
    var lineWidth: CGFloat
    var fill: Bool
    var fontSize: CGFloat = 24
    var textBackground = false
    var obfuscation: ObfuscationMode = .pixelate
}

struct EditorAnnotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case line(start: CGPoint, end: CGPoint)
        case arrow(start: CGPoint, end: CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case text(content: String, origin: CGPoint)
        case counter(center: CGPoint)
        case freehand(points: [CGPoint])
        case highlight(points: [CGPoint])
        case obfuscate(CGRect)
        case spotlight(CGRect)
    }

    let id: UUID
    var kind: Kind
    var style: AnnotationStyle

    init(id: UUID = UUID(), kind: Kind, style: AnnotationStyle) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    var isText: Bool {
        if case .text = kind {
            return true
        }
        return false
    }
}

// MARK: - Background

struct BackgroundPreset: Identifiable {
    let id: Int
    let colors: [Color]

    static let all: [BackgroundPreset] = [
        BackgroundPreset(id: 0, colors: [Color(red: 0.98, green: 0.45, blue: 0.62), Color(red: 0.55, green: 0.36, blue: 0.96)]),
        BackgroundPreset(id: 1, colors: [Color(red: 0.25, green: 0.62, blue: 0.98), Color(red: 0.36, green: 0.95, blue: 0.85)]),
        BackgroundPreset(id: 2, colors: [Color(red: 1.0, green: 0.62, blue: 0.29), Color(red: 0.98, green: 0.32, blue: 0.42)]),
        BackgroundPreset(id: 3, colors: [Color(red: 0.42, green: 0.86, blue: 0.52), Color(red: 0.13, green: 0.6, blue: 0.62)]),
        BackgroundPreset(id: 4, colors: [Color(red: 0.16, green: 0.18, blue: 0.3), Color(red: 0.42, green: 0.27, blue: 0.62)]),
        BackgroundPreset(id: 5, colors: [Color(red: 0.99, green: 0.86, blue: 0.45), Color(red: 0.98, green: 0.55, blue: 0.4)]),
        BackgroundPreset(id: 6, colors: [Color(red: 0.88, green: 0.9, blue: 0.94), Color(red: 0.7, green: 0.75, blue: 0.84)]),
        BackgroundPreset(id: 7, colors: [Color(red: 0.08, green: 0.08, blue: 0.1), Color(red: 0.24, green: 0.24, blue: 0.28)]),
    ]
}

enum BackgroundAspect: String, CaseIterable, Identifiable {
    case auto
    case wide
    case standard
    case square

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .wide: "16:9"
        case .standard: "4:3"
        case .square: "1:1"
        }
    }

    /// Ancho / alto, o `nil` para ajustarse al contenido.
    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .wide: 16.0 / 9.0
        case .standard: 4.0 / 3.0
        case .square: 1
        }
    }
}

struct BackgroundSettings: Equatable {
    var isEnabled = false
    var presetIndex = 0
    var padding: CGFloat = 64
    var cornerRadius: CGFloat = 12
    var shadow = true
    var aspect: BackgroundAspect = .auto
    /// Fondo de pantalla del usuario. Si existe, reemplaza al degradado.
    var wallpaper: CGImage?
    /// Desenfoque del fondo de pantalla, en pixeles de una imagen de referencia de 1600 px.
    var wallpaperBlur: CGFloat = 0

    var preset: BackgroundPreset {
        BackgroundPreset.all[min(max(presetIndex, 0), BackgroundPreset.all.count - 1)]
    }
}

// MARK: - Document

struct EditorDocument: Equatable {
    var annotations: [EditorAnnotation] = []
    /// Recorte en coordenadas de la imagen. `nil` usa la imagen completa.
    var cropRect: CGRect?
    var background = BackgroundSettings()
}
