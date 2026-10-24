import SwiftUI

// MARK: - Design Tokens

enum EditorColors {
    static let canvasBackground = Color(red: 0.075, green: 0.075, blue: 0.082)
    static let windowBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.13)
    static let toolbarBackground = Color(red: 0.133, green: 0.133, blue: 0.149)
    static let inspectorBackground = Color(red: 0.122, green: 0.122, blue: 0.137)
    static let groupBackground = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let chip = Color(red: 0.165, green: 0.165, blue: 0.188)
    static let chipSelected = Color(red: 0.227, green: 0.227, blue: 0.259)
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
            return EditorColors.chipSelected
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

// MARK: - Inspector controls

/// Uppercase section title for the side panels.
struct InspectorTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.white.opacity(0.6))
    }
}

/// Row of option buttons in the inspector style.
struct ChipRow<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selection == option ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(selection == option ? EditorColors.chipSelected : EditorColors.chip, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(selection == option ? Color.white : Color.white.opacity(0.75))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Slider with a title and value, for the side panels.
struct InspectorSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(Int(value))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

// MARK: - WindowDragArea

/// Empty area that lets you drag windows whose SwiftUI content covers the title bar.
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
