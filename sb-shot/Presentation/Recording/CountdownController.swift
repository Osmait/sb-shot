import AppKit
import Combine
import SwiftUI

/// Cuenta regresiva grande sobre el area seleccionada antes de grabar o capturar con temporizador.
final class CountdownController: CountdownPresenting {
    private final class Model: ObservableObject {
        @Published var value = 3
        var isCancelled = false
    }

    func countdown(seconds: Int, over selection: ScreenSelection) async -> Bool {
        guard seconds > 0 else { return true }

        let model = Model()
        model.value = seconds

        let size = CGSize(width: 150, height: 150)
        let frame = selection.frame
        let panel = KeyPanel(
            contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = FirstMouseHostingView(rootView: CountdownView(model: model) { model.isCancelled = true })
        // Se activa la app para que Esc llegue al monitor local aunque se haya iniciado con un atajo global.
        // Al terminar se devuelve el foco a la app que se va a grabar o capturar.
        let previousApp = AppFocus.activate()
        panel.makeKeyAndOrderFront(nil)

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                model.isCancelled = true
                return nil
            }
            return event
        }
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            panel.orderOut(nil)
            AppFocus.restore(previousApp)
        }

        for value in stride(from: seconds, to: 0, by: -1) {
            model.value = value
            for _ in 0 ..< 10 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if model.isCancelled {
                    return false
                }
            }
        }
        return !model.isCancelled
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool {
            true
        }
    }

    private struct CountdownView: View {
        @ObservedObject var model: Model
        let onCancel: () -> Void

        var body: some View {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.6))
                Circle()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 2)
                Text("\(model.value)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: model.value)
            }
            .frame(width: 130, height: 130)
            .frame(width: 150, height: 150)
            .contentShape(Circle())
            .onTapGesture(perform: onCancel)
            .help("Clic o Esc para cancelar")
        }
    }
}
