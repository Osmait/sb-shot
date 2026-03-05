import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: CaptureFlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(viewModel.isCapturing ? "Seleccionando..." : "Capturar region") {
                viewModel.captureRegion()
            }
            .disabled(viewModel.isCapturing)

            if let statusMessage = viewModel.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
