import SwiftUI

/// Button to use the current wallpaper as the background. Shows a thumbnail and reloads it on appear if the previous read is stale.
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
                        .scaledToFill()
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
                    Text("Wallpaper")
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
        .help("Use your current wallpaper")
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
