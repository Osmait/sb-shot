import AppKit

enum CaptureOutcome {
    case captured(NSImage, ScreenSelection)
    case cancelled
    case permissionDenied
    case failed
}

protocol ScreenCaptureProviding {
    /// Captura cada pantalla completa (sin las ventanas de la app) para la lupa y el modo congelado.
    func displaySnapshots() async throws -> [CGDirectDisplayID: CGImage]
    /// Igual que `displaySnapshots()`, pero puede ocultar los iconos del escritorio (modo congelado).
    func displaySnapshots(hidingDesktopIcons: Bool) async throws -> [CGDirectDisplayID: CGImage]
    func capture(_ selection: ScreenSelection, options: CaptureOptions) async throws -> NSImage
}

extension ScreenCaptureProviding {
    func displaySnapshots(hidingDesktopIcons _: Bool) async throws -> [CGDirectDisplayID: CGImage] {
        try await displaySnapshots()
    }
}

protocol ScreenPermissionChecking {
    func hasScreenRecordingAccess() -> Bool
    func requestScreenRecordingAccess() -> Bool
    func openScreenRecordingSettings()
    /// `true` si ya se mostro antes el aviso del sistema; la primera vez no se abren los Ajustes.
    func hasRequestedScreenRecordingAccess() -> Bool
}

extension ScreenPermissionChecking {
    func hasRequestedScreenRecordingAccess() -> Bool {
        true
    }
}

protocol ClipboardWriting {
    func copy(image: NSImage)
    func copy(text: String)
    func copy(fileURL: URL)
}

protocol RegionSelecting {
    func select(options: SelectionOptions) async -> SelectionResult?
    /// Pantalla bajo el cursor, para capturas o grabaciones de pantalla completa.
    func displayUnderCursor() -> ScreenSelection?
}

protocol CountdownPresenting: AnyObject {
    /// Muestra una cuenta regresiva sobre la seleccion. Devuelve `false` si el usuario la cancela.
    func countdown(seconds: Int, over selection: ScreenSelection) async -> Bool
}

protocol ScreenRecording: AnyObject {
    var onUnexpectedStop: ((Error?) -> Void)? { get set }
    /// Graba sin ninguna ventana de la app, salvo `visibleOwnWindowNumbers` (por ejemplo, el resaltado de clics).
    func start(_ selection: ScreenSelection, options: RecordingOptions, visibleOwnWindowNumbers: [Int]) async throws
    func stop() async throws -> URL
    func cancel() async
}

protocol TextRecognizing {
    func recognizeText(in image: NSImage) async throws -> String
}
