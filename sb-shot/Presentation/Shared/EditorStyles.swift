import SwiftUI

// MARK: - Design Tokens

enum EditorColors {
    static let canvasBackground = Color(red: 0.09, green: 0.09, blue: 0.1)
    static let windowBackground = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let hoverFill = Color.white.opacity(0.08)
    static let pressedFill = Color.white.opacity(0.12)
    static let groupBorder = Color.white.opacity(0.1)
}

// MARK: - ToolButton

struct ToolButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : .secondary)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return .accentColor
        } else if isHovered {
            return EditorColors.hoverFill
        }
        return .clear
    }
}

// MARK: - ActionButtonStyle

struct ActionButtonStyle: ButtonStyle {
    var isPrimary: Bool = true
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, isPrimary: isPrimary, isActive: isActive)
    }

    private struct ActionButtonBody: View {
        let configuration: Configuration
        let isPrimary: Bool
        let isActive: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(isPrimary ? Color.clear : EditorColors.groupBorder, lineWidth: 1)
                )
                .foregroundStyle(isPrimary || isActive ? .white : .secondary)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isHovered = hovering
                    }
                }
        }

        private var backgroundColor: Color {
            if isPrimary {
                if configuration.isPressed {
                    return .accentColor.opacity(0.8)
                }
                return isHovered ? .accentColor.opacity(0.9) : .accentColor
            }
            if isActive {
                return .accentColor.opacity(0.35)
            }
            if configuration.isPressed {
                return EditorColors.pressedFill
            }
            return isHovered ? EditorColors.hoverFill : .clear
        }
    }
}

// MARK: - WindowDragArea

/// Zona vacia que permite arrastrar ventanas cuyo contenido SwiftUI cubre la barra de titulo.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}

// MARK: - ToolbarGroupBackground

struct ToolbarGroupModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(EditorColors.groupBorder, lineWidth: 1))
    }
}

extension View {
    func toolbarGroup() -> some View {
        modifier(ToolbarGroupModifier())
    }
}
