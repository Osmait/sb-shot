import SwiftUI

/// Boton para usar el fondo de pantalla actual como fondo. Muestra una miniatura y lo vuelve a leer al aparecer si la lectura anterior es vieja.
struct WallpaperTile: View {
    let isSelected: Bool
    var height: CGFloat = 40
    let onSelect: (CGImage) -> Void

    @ObservedObject private var provider = WallpaperProvider.shared
    @State private var isLoading = false

    var body: some View {
        Button(action: select) {
            ZStack {
                if let thumbnail = provider.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .overlay(Color.black.opacity(0.25))
                } else {
                    EditorColors.chip
                }

                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "photo")
                    }
                    Text("Fondo de pantalla")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Usar tu fondo de pantalla actual")
        .task {
            await provider.refreshIfStale()
        }
    }

    private func select() {
        if let image = provider.image {
            onSelect(image)
            return
        }
        isLoading = true
        Task {
            defer { isLoading = false }
            if let image = await provider.refresh() {
                onSelect(image)
            } else {
                NSSound.beep()
            }
        }
    }
}
