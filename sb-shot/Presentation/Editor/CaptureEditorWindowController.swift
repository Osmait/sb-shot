import AppKit
import SwiftUI

final class CaptureEditorWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let viewModel: CaptureEditorViewModel
    private let actions: EditorActions
    private var keyMonitor: Any?

    init(image: NSImage, actions: EditorActions) {
        viewModel = CaptureEditorViewModel(baseImage: image)
        self.actions = actions

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.preferredSize(for: image)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Anotar captura"
        window.backgroundColor = NSColor(EditorColors.windowBackground)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 960, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)

        let renderedFile = { [weak viewModel] () -> URL? in
            guard let image = viewModel?.renderedImage() else { return nil }
            return Self.writeDragFile(for: image)
        }

        window.contentView = NSHostingView(rootView: CaptureEditorView(
            viewModel: viewModel,
            onCopy: { [weak self] in self?.copyImage() },
            onSave: { [weak self] in self?.saveImage() },
            onPin: { [weak self] in self?.pinImage() },
            dragFile: renderedFile
        ))
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
        onClose?()
    }

    // MARK: - Actions

    private func copyImage() {
        actions.onCopy(viewModel.renderedImage())
    }

    private func saveImage() {
        actions.onSave(viewModel.renderedImage())
    }

    private func saveImageAs() {
        actions.onSaveAs(viewModel.renderedImage())
    }

    private func pinImage() {
        actions.onPin(viewModel.renderedImage())
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window, event.window === window else { return event }
            return handleKey(event) ? nil : event
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Mientras se escribe texto solo se interceptan Esc y los comandos de guardar o copiar el resultado.
        let isTyping = viewModel.editingTextID != nil || window?.firstResponder is NSTextView
        if isTyping {
            if event.keyCode == 53 {
                viewModel.commitTextEditing()
                return true
            }
            return false
        }

        if flags.contains(.command) {
            switch (characters, flags.contains(.shift)) {
            case ("z", false): viewModel.undo()
            case ("z", true): viewModel.redo()
            case ("c", false): copyImage()
            case ("s", false): saveImage()
            case ("s", true): saveImageAs()
            case ("p", false): pinImage()
            default: return false
            }
            return true
        }

        switch event.keyCode {
        case 51, 117:
            viewModel.deleteSelection()
            return true
        case 53:
            if viewModel.isCropping {
                viewModel.cancelCrop()
            } else {
                viewModel.deselect()
            }
            return true
        case 36, 76:
            if viewModel.isCropping {
                viewModel.confirmCrop()
                return true
            }
            return false
        default:
            break
        }

        guard flags.subtracting(.shift).isEmpty, let key = characters.first else { return false }
        if let tool = EditorTool.allCases.first(where: { $0.shortcutKey == key }) {
            viewModel.activeTool = tool
            return true
        }
        return false
    }

    // MARK: - Helpers

    private static func writeDragFile(for image: NSImage) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-shot", isDirectory: true)
            .appendingPathComponent("captura-editada.png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
        else { return nil }

        try? data.write(to: url, options: .atomic)
        return url
    }

    private static func preferredSize(for image: NSImage) -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let width = min(max(image.size.width + 120, 1000), screen.width * 0.9)
        let height = min(max(image.size.height + 200, 640), screen.height * 0.9)
        return NSSize(width: width, height: height)
    }
}

// MARK: - Root view

private struct CaptureEditorView: View {
    @ObservedObject var viewModel: CaptureEditorViewModel
    let onCopy: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let dragFile: () -> URL?

    var body: some View {
        VStack(spacing: 0) {
            EditorTopBar(viewModel: viewModel, onCopy: onCopy, onSave: onSave, onPin: onPin, dragFile: dragFile)
                .padding(.leading, 84)
                .padding(.trailing, 12)
                .frame(height: 52)
                .background(WindowDragArea())
                .background(EditorColors.toolbarBackground)

            Divider().overlay(EditorColors.groupBorder)

            HStack(spacing: 0) {
                EditorCanvasView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(EditorColors.groupBorder)

                EditorInspector(viewModel: viewModel)
                    .frame(width: 288)
            }
        }
        .background(EditorColors.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - Top bar

private struct EditorTopBar: View {
    @ObservedObject var viewModel: CaptureEditorViewModel
    let onCopy: () -> Void
    let onSave: () -> Void
    let onPin: () -> Void
    let dragFile: () -> URL?

    private static let annotateTools: [EditorTool] = [.select, .arrow, .line, .rectangle, .ellipse, .text, .counter]
    private static let effectTools: [EditorTool] = [.pencil, .highlighter, .obfuscate, .spotlight, .crop]

    var body: some View {
        HStack(spacing: 12) {
            toolGroup(Self.annotateTools)
            toolGroup(Self.effectTools)

            Spacer(minLength: 0)

            iconButton("arrow.uturn.backward", help: "Deshacer (⌘Z)", enabled: viewModel.canUndo, action: viewModel.undo)
            iconButton("arrow.uturn.forward", help: "Rehacer (⇧⌘Z)", enabled: viewModel.canRedo, action: viewModel.redo)

            DragChip(dragFile: dragFile)
            iconButton("pin", help: "Fijar en pantalla (⌘P)", enabled: true, action: onPin)

            Button("Guardar", action: onSave)
                .buttonStyle(ActionButtonStyle(isPrimary: false))
                .help("Guardar en la carpeta de capturas (⌘S) · Guardar como (⇧⌘S)")

            Button("Copiar", action: onCopy)
                .buttonStyle(ActionButtonStyle())
                .help("Copiar al portapapeles (⌘C)")
        }
    }

    private func toolGroup(_ tools: [EditorTool]) -> some View {
        HStack(spacing: 2) {
            ForEach(tools) { tool in
                ToolButton(icon: tool.iconName, isSelected: viewModel.activeTool == tool) {
                    viewModel.activeTool = tool
                }
                .help("\(tool.title) (\(String(tool.shortcutKey).uppercased()))")
            }
        }
        .padding(3)
        .background(EditorColors.groupBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(EditorColors.groupBorder, lineWidth: 1))
    }

    private func iconButton(_ systemName: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.25))
        .disabled(!enabled)
        .help(help)
    }
}

/// Icono que se arrastra para soltar la imagen editada en otra app.
private struct DragChip: View {
    let dragFile: () -> URL?

    var body: some View {
        ZStack {
            Image(systemName: "hand.draw")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))

            FileDragSource(fileURL: dragFile, previewImage: nil)
        }
        .frame(width: 30, height: 30)
        .help("Arrastra la captura a otra app")
    }
}

// MARK: - Inspector

private struct EditorInspector: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if viewModel.isCropping {
                    CropSection(viewModel: viewModel)
                } else {
                    StyleSection(viewModel: viewModel)
                }

                Rectangle()
                    .fill(EditorColors.groupBorder)
                    .frame(height: 1)

                BackgroundSection(viewModel: viewModel)
            }
            .padding(18)
        }
        .scrollIndicators(.never)
        .background(EditorColors.inspectorBackground)
    }
}

private struct StyleSection: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    private var tool: EditorTool {
        viewModel.styleTool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorTitle(viewModel.selectedAnnotation == nil ? "Herramienta · \(tool.title)" : "Selección · \(tool.title)")

            if tool == .select, viewModel.selectedAnnotation == nil {
                Text("Haz clic en una anotación para editarla. Arrástrala para moverla y usa los puntos para cambiar su tamaño.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if tool.usesColor {
                ColorGrid(selection: $viewModel.strokeColor)
            }

            if tool.usesStrokeWidth {
                InspectorSlider(title: "Grosor", value: $viewModel.lineWidth, range: 1 ... 16)
            }

            if tool == .rectangle || tool == .ellipse {
                ChipRow(options: [false, true], selection: $viewModel.fillShapes) { $0 ? "Relleno" : "Contorno" }
            }

            if tool == .text {
                InspectorSlider(title: "Tamaño", value: $viewModel.fontSize, range: 12 ... 120)
                ChipRow(options: [false, true], selection: $viewModel.textBackground) { $0 ? "Con fondo" : "Simple" }
            }

            if tool == .obfuscate {
                ChipRow(options: ObfuscationMode.allCases, selection: $viewModel.obfuscation) { $0.title }
            }

            if tool == .spotlight {
                Text("Oscurece todo menos las zonas que marques.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if viewModel.selectedAnnotation != nil {
                Button(role: .destructive, action: viewModel.deleteSelection) {
                    Label("Eliminar", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionButtonStyle(isPrimary: false))
                .help("Eliminar (⌫)")
            }
        }
    }
}

private struct CropSection: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            InspectorTitle("Recorte")

            Text("Arrastra sobre la imagen o mueve las esquinas. Enter aplica y Esc cancela.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let draft = viewModel.cropDraft {
                Text(verbatim: "\(Int(draft.width)) × \(Int(draft.height))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }

            HStack(spacing: 6) {
                Button("Restablecer", action: viewModel.resetCrop)
                    .buttonStyle(ActionButtonStyle(isPrimary: false))
                Button("Cancelar", action: viewModel.cancelCrop)
                    .buttonStyle(ActionButtonStyle(isPrimary: false))
                Button("Aplicar", action: viewModel.confirmCrop)
                    .buttonStyle(ActionButtonStyle())
            }
        }
    }
}

private struct BackgroundSection: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    private var background: BackgroundSettings {
        viewModel.document.background
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                InspectorTitle("Fondo")
                Spacer()
                Toggle("Fondo", isOn: Binding(
                    get: { background.isEnabled },
                    set: { value in viewModel.updateBackground { $0.isEnabled = value } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(BackgroundPreset.all) { preset in
                    Button {
                        viewModel.updateBackground {
                            $0.presetIndex = preset.id
                            $0.isEnabled = true
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 40)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .opacity(background.isEnabled && background.presetIndex == preset.id ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            InspectorSlider(title: "Margen", value: backgroundBinding(\.padding, key: "padding"), range: 0 ... 200)
            InspectorSlider(title: "Esquinas", value: backgroundBinding(\.cornerRadius, key: "radius"), range: 0 ... 40)

            Toggle(isOn: Binding(
                get: { background.shadow },
                set: { value in viewModel.updateBackground { $0.shadow = value } }
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
                            viewModel.updateBackground {
                                $0.aspect = value
                                $0.isEnabled = true
                            }
                        }
                    )
                ) { $0.title }
            }
        }
        .opacity(viewModel.isCropping ? 0.5 : 1)
        .disabled(viewModel.isCropping)
    }

    private func backgroundBinding(_ keyPath: WritableKeyPath<BackgroundSettings, CGFloat>, key: String) -> Binding<CGFloat> {
        Binding(
            get: { background[keyPath: keyPath] },
            set: { value in
                viewModel.updateBackground(coalesceKey: key) {
                    $0[keyPath: keyPath] = value
                    $0.isEnabled = true
                }
            }
        )
    }
}

// MARK: - Inspector controls

private struct ColorGrid: View {
    @Binding var selection: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(Array(CaptureEditorViewModel.palette.enumerated()), id: \.offset) { _, color in
                    Button {
                        selection = color
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2).opacity(selection == color ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                ColorPicker("Otro color", selection: $selection, supportsOpacity: false)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
