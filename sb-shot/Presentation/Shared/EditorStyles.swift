import SwiftUI

// MARK: - Design Tokens

enum EditorColors {
    static let canvasBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let windowBackground = Color(red: 0.15, green: 0.15, blue: 0.16)
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
                .frame(width: 30, height: 26)
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
            return .white.opacity(0.08)
        }
        return .clear
    }
}

// MARK: - ActionButtonStyle

struct ActionButtonStyle: ButtonStyle {
    var isPrimary: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(backgroundColor(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(isPrimary ? .white : .secondary)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPrimary {
            if isPressed {
                return .accentColor.opacity(0.8)
            } else if isHovered {
                return .accentColor.opacity(0.9)
            }
            return .accentColor
        } else {
            if isPressed {
                return .white.opacity(0.12)
            } else if isHovered {
                return .white.opacity(0.08)
            }
            return .clear
        }
    }
}

// MARK: - PreviewToolButtonStyle

struct PreviewToolButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(width: 26, height: 26)
            .background(
                configuration.isPressed ? EditorColors.pressedFill :
                    isHovered ? EditorColors.hoverFill : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .foregroundStyle(.secondary)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}

// MARK: - ToolbarGroupBackground

struct ToolbarGroupModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(EditorColors.groupBorder, lineWidth: 1))
    }
}

extension View {
    func toolbarGroup() -> some View {
        modifier(ToolbarGroupModifier())
    }
}
