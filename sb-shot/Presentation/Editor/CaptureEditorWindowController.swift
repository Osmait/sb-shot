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
            EditorToolbar(viewModel: viewModel)
                .padding(.leading, 84)
                .padding(.trailing, 12)
                .frame(height: 52)
                .background(WindowDragArea())

            Divider().overlay(EditorColors.groupBorder)

            HStack(spacing: 0) {
                EditorCanvasView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.showsBackgroundPanel {
                    Divider().overlay(EditorColors.groupBorder)
                    BackgroundInspector(viewModel: viewModel)
                        .frame(width: 250)
                        .transition(.move(edge: .trailing))
                }
            }

            Divider().overlay(EditorColors.groupBorder)

            bottomBar
                .padding(.horizontal, 12)
                .frame(height: 48)
        }
        .background(EditorColors.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showsBackgroundPanel)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.showsBackgroundPanel.toggle()
            } label: {
                Label("Fondo", systemImage: "square.on.square.squareshape.controlhandles")
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false, isActive: viewModel.showsBackgroundPanel))
            .help("Agregar fondo, margen y sombra")

            Button {
                viewModel.clear()
            } label: {
                Label("Limpiar", systemImage: "trash")
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false))
            .disabled(viewModel.document.annotations.isEmpty)

            Spacer()

            Text("\(Int(viewModel.outputPixelSize.width)) × \(Int(viewModel.outputPixelSize.height)) px")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            DragChip(dragFile: dragFile)

            Button(action: onPin) {
                Image(systemName: "pin")
            }
            .buttonStyle(ActionButtonStyle(isPrimary: false))
            .help("Fijar en pantalla (⌘P)")

            Button("Guardar", action: onSave)
                .buttonStyle(ActionButtonStyle(isPrimary: false))
                .help("Guardar en la carpeta de capturas (⌘S) · Guardar como (⇧⌘S)")

            Button(action: onCopy) {
                Label("Copiar", systemImage: "doc.on.doc")
            }
            .buttonStyle(ActionButtonStyle())
            .help("Copiar al portapapeles (⌘C)")
        }
    }
}

/// Chip que se arrastra para soltar la imagen editada en otra app.
private struct DragChip: View {
    let dragFile: () -> URL?

    var body: some View {
        ZStack {
            Label("Arrastrar", systemImage: "hand.draw")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(EditorColors.hoverFill, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(EditorColors.groupBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))

            FileDragSource(fileURL: dragFile, previewImage: nil)
        }
        .fixedSize()
        .help("Arrastra la captura a otra app")
    }
}

// MARK: - Toolbar

private struct EditorToolbar: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    ToolButton(icon: tool.iconName, isSelected: viewModel.activeTool == tool) {
                        viewModel.activeTool = tool
                    }
                    .help("\(tool.title) (\(String(tool.shortcutKey).uppercased()))")
                }
            }
            .toolbarGroup()

            if viewModel.isCropping {
                cropControls
            } else {
                StyleControls(viewModel: viewModel, tool: viewModel.styleTool)
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                iconButton("arrow.uturn.backward", help: "Deshacer (⌘Z)", enabled: viewModel.canUndo, action: viewModel.undo)
                iconButton("arrow.uturn.forward", help: "Rehacer (⇧⌘Z)", enabled: viewModel.canRedo, action: viewModel.redo)
            }
            .toolbarGroup()
        }
    }

    private var cropControls: some View {
        HStack(spacing: 6) {
            Button("Restablecer", action: viewModel.resetCrop)
                .buttonStyle(ActionButtonStyle(isPrimary: false))
            Button("Cancelar", action: viewModel.cancelCrop)
                .buttonStyle(ActionButtonStyle(isPrimary: false))
            Button("Aplicar", action: viewModel.confirmCrop)
                .buttonStyle(ActionButtonStyle())
        }
        .toolbarGroup()
    }

    private func iconButton(_ systemName: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .white : .white.opacity(0.25))
        .disabled(!enabled)
        .help(help)
    }
}

private struct StyleControls: View {
    @ObservedObject var viewModel: CaptureEditorViewModel
    let tool: EditorTool

    var body: some View {
        HStack(spacing: 8) {
            if tool.usesColor {
                ColorSwatches(selection: $viewModel.strokeColor)
            }

            if tool.usesStrokeWidth {
                compactSlider(icon: "lineweight", value: $viewModel.lineWidth, range: 1 ... 16, help: "Grosor")
            }

            if tool == .rectangle || tool == .ellipse {
                ToolButton(icon: viewModel.fillShapes ? "square.fill" : "square", isSelected: viewModel.fillShapes) {
                    viewModel.fillShapes.toggle()
                }
                .help("Relleno")
            }

            if tool == .text {
                compactSlider(icon: "textformat.size", value: $viewModel.fontSize, range: 12 ... 120, help: "Tamaño de texto")
                ToolButton(icon: "character.textbox", isSelected: viewModel.textBackground) {
                    viewModel.textBackground.toggle()
                }
                .help("Texto con fondo")
            }

            if tool == .obfuscate {
                Picker("", selection: $viewModel.obfuscation) {
                    ForEach(ObfuscationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            if tool == .select, viewModel.selectedAnnotation == nil {
                Text("Clic para seleccionar · Arrastra para mover · ⌫ para borrar")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .toolbarGroup()
        .fixedSize()
    }

    private func compactSlider(icon: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .controlSize(.small)
                .frame(width: 80)
        }
        .help(help)
    }
}

private struct ColorSwatches: View {
    @Binding var selection: Color

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(CaptureEditorViewModel.palette.enumerated()), id: \.offset) { _, color in
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 2)
                                .padding(-3)
                                .opacity(selection == color ? 1 : 0)
                        )
                }
                .buttonStyle(.plain)
            }

            ColorPicker("", selection: $selection, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 22)
                .help("Otro color")
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Background inspector

private struct BackgroundInspector: View {
    @ObservedObject var viewModel: CaptureEditorViewModel

    private var background: BackgroundSettings {
        viewModel.document.background
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: Binding(
                    get: { background.isEnabled },
                    set: { value in viewModel.updateBackground { $0.isEnabled = value } }
                )) {
                    Text("Fondo")
                        .font(.system(size: 13, weight: .semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Estilo")
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 8), count: 4), spacing: 8) {
                        ForEach(BackgroundPreset.all) { preset in
                            Button {
                                viewModel.updateBackground {
                                    $0.presetIndex = preset.id
                                    $0.isEnabled = true
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 48, height: 34)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(Color.white, lineWidth: 2)
                                            .opacity(background.isEnabled && background.presetIndex == preset.id ? 1 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                slider("Margen", value: background.padding, range: 0 ... 200, key: "padding") { $0.padding = $1 }
                slider("Esquinas", value: background.cornerRadius, range: 0 ... 40, key: "radius") { $0.cornerRadius = $1 }

                Toggle("Sombra", isOn: Binding(
                    get: { background.shadow },
                    set: { value in viewModel.updateBackground { $0.shadow = value } }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("El fondo se aplica al copiar, guardar o arrastrar la captura.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .disabled(false)
        }
        .background(EditorColors.panelBackground)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func slider(
        _ title: String,
        value: CGFloat,
        range: ClosedRange<CGFloat>,
        key: String,
        apply: @escaping (inout BackgroundSettings, CGFloat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle(title)
                Spacer()
                Text("\(Int(value))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { value },
                    set: { newValue in
                        viewModel.updateBackground(coalesceKey: key) {
                            apply(&$0, newValue)
                            $0.isEnabled = true
                        }
                    }
                ),
                in: range
            )
            .controlSize(.small)
        }
    }
}
