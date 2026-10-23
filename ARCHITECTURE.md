# Arquitectura de sb-shot

Herramienta de captura de pantalla para macOS con editor de anotaciones integrado.

## Stack Tecnologico

| Tecnologia | Uso |
|---|---|
| Swift 6 | Lenguaje principal |
| SwiftUI | Vistas declarativas (menus, settings, editor UI) |
| AppKit | Window controllers, NSPanel, NSPasteboard |
| ScreenCaptureKit | Captura de pantalla multi-monitor |
| Carbon Events | Atajos de teclado globales |
| CoreGraphics | Renderizado de anotaciones para exportacion |

## Estructura de Capas

El proyecto sigue **Clean Architecture** con 4 capas bien definidas:

```
┌──────────────────────────────────────────┐
│              App (Entry Point)           │
│   SbShotApp · AppContainer · Settings    │
├──────────────────────────────────────────┤
│           Presentation (UI)              │
│  ViewModels · WindowControllers · Views  │
├──────────────────────────────────────────┤
│       Infrastructure (Servicios)         │
│   Capture · Clipboard · Hotkey · Perms   │
├──────────────────────────────────────────┤
│         Domain (Logica de negocio)       │
│   Contracts · Models · Use Cases         │
└──────────────────────────────────────────┘
```

### Diagrama de Capas

```mermaid
graph TB
    subgraph App["App Layer"]
        SbShotApp["SbShotApp<br/><small>@main entry point</small>"]
        AppContainer["AppContainer<br/><small>Dependency Injection</small>"]
        ShortcutStore["ShortcutSettingsStore<br/><small>UserDefaults persistence</small>"]
    end

    subgraph Presentation["Presentation Layer"]
        FlowVM["CaptureFlowViewModel<br/><small>Orquestador del flujo</small>"]
        EditorVM["CaptureEditorViewModel<br/><small>Estado del editor</small>"]
        PreviewWC["CapturePreviewWindowController"]
        EditorWC["CaptureEditorWindowController"]
        ThumbnailC["CaptureThumbnailController"]
        MenuBar["MenuBarView"]
        SettingsV["SettingsView"]
    end

    subgraph Infrastructure["Infrastructure Layer"]
        ScreenCapture["ScreenCaptureService"]
        Clipboard["ClipboardService"]
        Permission["PermissionService"]
        Hotkey["HotkeyManager"]
        Selection["SelectionOverlayController"]
        Renderer["AnnotationRenderer"]
        Adapters["SystemAdapters<br/><small>Presenter implementations</small>"]
    end

    subgraph Domain["Domain Layer"]
        UseCase["CaptureRegionUseCase"]
        Contracts["Protocols<br/><small>ScreenCaptureProviding<br/>ScreenPermissionChecking<br/>ClipboardWriting<br/>RegionSelecting</small>"]
        Models["EditorModels<br/><small>EditorTool, AnnotationStyle<br/>EditorAnnotation</small>"]
    end

    SbShotApp --> AppContainer
    AppContainer --> FlowVM
    AppContainer --> ShortcutStore
    AppContainer --> Hotkey

    FlowVM --> UseCase
    FlowVM --> Adapters
    EditorVM --> Renderer

    Adapters --> PreviewWC
    Adapters --> EditorWC
    Adapters --> ThumbnailC
    Adapters --> Selection

    UseCase --> Contracts

    ScreenCapture -.->|implements| Contracts
    Clipboard -.->|implements| Contracts
    Permission -.->|implements| Contracts
    Selection -.->|implements| Contracts

    MenuBar --> FlowVM
    SettingsV --> ShortcutStore

    style Domain fill:#e8f5e9
    style Infrastructure fill:#e3f2fd
    style Presentation fill:#fff3e0
    style App fill:#fce4ec
```

## Flujo de Captura

```mermaid
sequenceDiagram
    actor User
    participant MenuBar
    participant FlowVM as CaptureFlowViewModel
    participant UseCase as CaptureRegionUseCase
    participant Perms as PermissionService
    participant Selection as SelectionOverlay
    participant Capture as ScreenCaptureService
    participant Clipboard as ClipboardService
    participant Thumbnail as ThumbnailController

    User->>MenuBar: Click "Capturar region"
    MenuBar->>FlowVM: captureRegion()
    FlowVM->>UseCase: execute()

    UseCase->>Perms: hasScreenRecordingAccess()
    alt Sin permiso
        Perms-->>UseCase: false
        UseCase->>Perms: requestScreenRecordingAccess()
        Perms-->>UseCase: false
        UseCase->>Perms: openScreenRecordingSettings()
        UseCase-->>FlowVM: .permissionDenied
    end

    UseCase->>Selection: selectRegion()
    Note over Selection: Overlay fullscreen<br/>con cursor crosshair
    User->>Selection: Drag para seleccionar region
    Selection-->>UseCase: CGRect (region)

    UseCase->>Capture: captureRegion(rect)
    Note over Capture: ScreenCaptureKit<br/>Multi-display support
    Capture-->>UseCase: NSImage

    UseCase->>Clipboard: copy(image)
    UseCase-->>FlowVM: .captured(image)

    FlowVM->>Thumbnail: show(image)
    Note over Thumbnail: Auto-cierre 5s<br/>Hover muestra acciones
```

## Flujo del Editor

```mermaid
sequenceDiagram
    actor User
    participant Thumbnail as ThumbnailController
    participant FlowVM as CaptureFlowViewModel
    participant EditorWC as EditorWindowController
    participant EditorVM as EditorViewModel
    participant Renderer as AnnotationRenderer
    participant Clipboard as ClipboardService

    User->>Thumbnail: Click "Editar"
    Thumbnail->>FlowVM: onEdit()
    FlowVM->>EditorWC: show(image, onCopy)

    loop Anotaciones
        User->>EditorWC: Seleccionar herramienta + Dibujar
        EditorWC->>EditorVM: add(annotation)
        EditorVM->>EditorVM: pushUndoSnapshot()
    end

    alt Copiar
        User->>EditorWC: Click "Copiar"
        EditorWC->>EditorVM: renderedImage()
        EditorVM->>Renderer: render(base, annotations)
        Renderer-->>EditorVM: NSImage final
        EditorWC->>FlowVM: onCopy(editedImage)
        FlowVM->>Clipboard: copy(image)
    end

    alt Guardar PNG
        User->>EditorWC: Click "Guardar PNG"
        EditorWC->>EditorVM: renderedImage()
        Note over EditorWC: NSSavePanel
    end
```

## Inyeccion de Dependencias

```mermaid
graph LR
    subgraph AppContainer
        direction TB
        AC["AppContainer"]

        AC -->|creates| PS[PermissionService]
        AC -->|creates| CS[ClipboardService]
        AC -->|creates| SCS[ScreenCaptureService]
        AC -->|creates| SOC[SelectionOverlayRegionSelector]
        AC -->|creates| HM[HotkeyManager]
        AC -->|creates| PWP[PreviewWindowPresenter]
        AC -->|creates| EWP[EditorWindowPresenter]
        AC -->|creates| TWP[ThumbnailWindowPresenter]

        AC -->|assembles| UC[CaptureRegionUseCase]
        UC -.->|uses| PS
        UC -.->|uses| CS
        UC -.->|uses| SCS
        UC -.->|uses| SOC

        AC -->|assembles| VM[CaptureFlowViewModel]
        VM -.->|uses| UC
        VM -.->|uses| PWP
        VM -.->|uses| EWP
        VM -.->|uses| TWP
        VM -.->|uses| CS
    end
```

## Protocolos (Contracts)

Todos los servicios implementan protocolos definidos en el dominio, permitiendo testabilidad y desacoplamiento:

```mermaid
classDiagram
    class ScreenCaptureProviding {
        <<protocol>>
        +captureRegion(CGRect) async throws NSImage
    }

    class ScreenPermissionChecking {
        <<protocol>>
        +hasScreenRecordingAccess() Bool
        +requestScreenRecordingAccess() Bool
        +openScreenRecordingSettings()
    }

    class ClipboardWriting {
        <<protocol>>
        +copy(image: NSImage)
    }

    class RegionSelecting {
        <<protocol>>
        +selectRegion() async CGRect?
    }

    class PreviewPresenting {
        <<protocol>>
        +show(image, onCopy, onEdit)
    }

    class ThumbnailPresenting {
        <<protocol>>
        +show(image, onOpen, onEdit, onCopy)
    }

    class EditorPresenting {
        <<protocol>>
        +show(image, onCopy)
    }

    ScreenCaptureService ..|> ScreenCaptureProviding
    PermissionService ..|> ScreenPermissionChecking
    ClipboardService ..|> ClipboardWriting
    SelectionOverlayRegionSelector ..|> RegionSelecting
    PreviewWindowPresenter ..|> PreviewPresenting
    ThumbnailWindowPresenter ..|> ThumbnailPresenting
    EditorWindowPresenter ..|> EditorPresenting
```

## Modelo de Anotaciones

```mermaid
classDiagram
    class EditorAnnotation {
        +id: UUID
        +kind: Kind
        +style: AnnotationStyle
    }

    class Kind {
        <<enum>>
        line(start, end)
        arrow(start, end)
        rectangle(CGRect)
        ellipse(CGRect)
        text(content, origin)
        freehand(points)
    }

    class AnnotationStyle {
        +color: Color
        +lineWidth: CGFloat
        +fill: Bool
    }

    class EditorTool {
        <<enum>>
        line
        arrow
        rectangle
        ellipse
        text
        pencil
    }

    EditorAnnotation --> Kind
    EditorAnnotation --> AnnotationStyle
    EditorTool ..> Kind : maps to
```

## Estructura de Archivos

```
sb-shot/
├── App/
│   ├── SbShotApp.swift              # @main, MenuBarExtra, Settings scene
│   ├── AppContainer.swift           # DI container, wiring de dependencias
│   └── ShortcutSettingsStore.swift   # Persistencia del atajo global
│
├── Domain/
│   ├── CaptureContracts.swift       # 4 protocolos del dominio
│   ├── EditorModels.swift           # EditorTool, AnnotationStyle, EditorAnnotation
│   └── CaptureRegionUseCase.swift   # Logica: permisos → seleccion → captura → clipboard
│
├── Infrastructure/
│   ├── Capture/
│   │   └── ScreenCaptureService.swift      # ScreenCaptureKit, multi-display
│   ├── Clipboard/
│   │   └── ClipboardService.swift          # NSPasteboard wrapper
│   ├── Hotkey/
│   │   └── HotkeyManager.swift             # Carbon Events, registro de hotkeys
│   ├── Permissions/
│   │   └── PermissionService.swift         # CGPreflightScreenCaptureAccess
│   ├── Rendering/
│   │   ├── AnnotationRenderer.swift        # CoreGraphics rendering a NSImage
│   │   ├── ArrowGeometry.swift             # Calculo geometrico compartido de flechas
│   │   └── ImageExporter.swift             # Exportacion PNG via NSSavePanel
│   ├── Selection/
│   │   └── SelectionOverlayController.swift # Overlay fullscreen + drag selection
│   └── SystemAdapters.swift                # Implementaciones de Presenter protocols
│
└── Presentation/
    ├── CapturePresenting.swift             # Protocolos de presentacion
    ├── Capture/
    │   └── CaptureFlowViewModel.swift      # Orquestador principal del flujo
    ├── Editor/
    │   ├── CaptureEditorViewModel.swift    # Estado del editor, undo/redo
    │   └── CaptureEditorWindowController.swift # Ventana del editor + canvas
    ├── MenuBar/
    │   └── MenuBarView.swift               # Menu de la barra de estado
    ├── Preview/
    │   └── CapturePreviewWindowController.swift # Ventana de vista previa
    ├── Settings/
    │   └── SettingsView.swift              # Configuracion del atajo global
    └── Thumbnail/
        └── CaptureThumbnailController.swift # Thumbnail flotante post-captura
```

## Patrones Utilizados

| Patron | Donde | Proposito |
|---|---|---|
| Clean Architecture | Todo el proyecto | Separacion de capas |
| Use Case | `CaptureRegionUseCase` | Orquestar logica de negocio |
| Protocol-Based Design | `CaptureContracts`, `CapturePresenting` | Desacoplamiento, testabilidad |
| Dependency Injection | `AppContainer` | Composicion de dependencias |
| Observable/MVVM | `CaptureFlowViewModel`, `CaptureEditorViewModel` | State management reactivo |
| Presenter | `SystemAdapters` | Gestionar ciclo de vida de ventanas |
| Undo/Redo Stack | `CaptureEditorViewModel` | Historial de edicion (max 100) |

## Como Contribuir

### Prerequisitos

- macOS 14+ (Sonoma)
- Xcode 16+
- Swift 6

### Herramientas de Calidad

```bash
# Formatear codigo
swiftformat sb-shot/ sb-shotTests/ sb-shotUITests/

# Lint
swiftlint lint

# Lint con auto-correccion
swiftlint lint --fix
```

### Agregar un Nuevo Servicio

1. Definir el protocolo en `Domain/CaptureContracts.swift`
2. Implementar en `Infrastructure/NuevoServicio/`
3. Agregar conformance con extension: `extension MiServicio: MiProtocolo {}`
4. Registrar en `AppContainer`

### Agregar una Nueva Herramienta de Editor

1. Agregar caso a `EditorTool` en `Domain/EditorModels.swift`
2. Agregar caso a `EditorAnnotation.Kind`
3. Implementar rendering en `AnnotationRenderer` (para export PNG)
4. Implementar rendering en `CaptureEditorCanvasView` (para preview en canvas)
5. Agregar gesture handling en `editorGesture` / `commitDrag` / `annotationForDrag`
6. Agregar preview en `previewAnnotation()`

### Convenciones

- **Idioma del codigo**: Ingles para identificadores, espanol para strings de UI
- **Formato**: SwiftFormat con `.swiftformat` del proyecto
- **Lint**: SwiftLint con `.swiftlint.yml` del proyecto
- **Arquitectura**: Respetar la separacion de capas (Domain no importa frameworks)
- **Window Controllers**: Usar patron `init → super.init → show()` existente
- **Protocolos**: Implementar conformance como extension separada
