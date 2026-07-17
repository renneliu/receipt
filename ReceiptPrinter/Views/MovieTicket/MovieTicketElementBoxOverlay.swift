import AppKit
import SwiftUI

/// Draggable / resizable box for movie-ticket template canvas elements.
struct MovieTicketElementBoxOverlay: View {
    @Binding var frame: SequencePlaceholderFrame
    @Binding var isSelected: Bool
    var title: String
    var previewText: String
    var fontSize: CGFloat
    /// 0 left, 1 center, 2 right — matches `MovieTicketElement.alignment`.
    var textAlignment: Int = 0
    var paperSize: CGSize
    var gridEnabled: Bool
    var gridSize: CGFloat
    var accent: Color = .blue
    /// When true, only selection chrome is drawn — ink comes from a print-preview underlay.
    var chromeOnly: Bool = false
    /// Editor mode: show a labeled placeholder block (not a fake print-style preview).
    var placeholderMode: Bool = false
    /// When true, position drag is disabled (resize still allowed).
    var isLocked: Bool = false
    /// Minimum resize size (defaults match legacy; print placeholders may use a shorter min height).
    var minSize: CGSize = CGSize(width: 36, height: 22)
    var onFrameChanged: (() -> Void)? = nil
    /// true while drag/resize is active so the parent can skip expensive live recomposes.
    var onInteractionChanged: ((Bool) -> Void)? = nil
    /// `additive` is true when ⌘ is held (toggle multi-select).
    var onSelectRequest: ((_ additive: Bool) -> Void)? = nil
    /// When set, position drag reports translation from gesture start (parent moves selection).
    var onTranslateChanged: ((CGSize) -> Void)? = nil
    var onTranslateEnded: (() -> Void)? = nil

    @State private var dragStart: SequencePlaceholderFrame?
    @State private var resizeStart: SequencePlaceholderFrame?

    private var frameAlignment: Alignment {
        switch textAlignment {
        case 1: return .center
        case 2: return .trailing
        default: return .leading
        }
    }

    private var multilineAlignment: TextAlignment {
        switch textAlignment {
        case 1: return .center
        case 2: return .trailing
        default: return .leading
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if chromeOnly {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.001))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        isSelected ? accent : accent.opacity(0.35),
                        lineWidth: isSelected ? 2 : 1
                    )
            } else if placeholderMode {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent.opacity(isSelected ? 0.18 : 0.10))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        isSelected ? accent : accent.opacity(0.55),
                        style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [4, 3])
                    )
                Text(previewText.isEmpty ? "[\(title)]" : previewText)
                    .font(.system(size: 9, weight: .medium, design: .default))
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 2)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent.opacity(isSelected ? 0.14 : 0.08))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? accent : accent.opacity(0.5), lineWidth: isSelected ? 2 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    if isSelected {
                        HStack(spacing: 2) {
                            Text(title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(accent)
                            if isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                    Text(previewText.isEmpty ? " " : previewText)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(multilineAlignment)
                        .lineLimit(4)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
                }
                .padding(4)
            }

            if isSelected {
                if chromeOnly || placeholderMode {
                    HStack(spacing: 2) {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(accent)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(accent)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(2)
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(accent)
                            .frame(width: 10, height: 10)
                            .padding(2)
                            .gesture(resizeGesture)
                    }
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(Rectangle())
        .position(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        .gesture(dragGesture)
        .onTapGesture {
            if let onSelectRequest {
                onSelectRequest(NSEvent.modifierFlags.contains(.command))
            } else {
                isSelected = true
            }
        }
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        guard gridEnabled, gridSize > 0 else { return value }
        return (value / gridSize).rounded() * gridSize
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil {
                    if let onSelectRequest {
                        if !isSelected {
                            onSelectRequest(false)
                        }
                    } else {
                        isSelected = true
                    }
                    dragStart = frame
                    onInteractionChanged?(true)
                }
                guard !isLocked else { return }
                if let onTranslateChanged {
                    onTranslateChanged(value.translation)
                    return
                }
                guard let start = dragStart else { return }
                var next = start
                next.x = snap(start.x + value.translation.width)
                next.y = snap(start.y + value.translation.height)
                frame = next.clamped(to: paperSize, minSize: minSize)
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                onInteractionChanged?(false)
                if let onTranslateEnded {
                    onTranslateEnded()
                } else {
                    onFrameChanged?()
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if let onSelectRequest {
                    if !isSelected { onSelectRequest(false) }
                } else {
                    isSelected = true
                }
                if resizeStart == nil {
                    resizeStart = frame
                    onInteractionChanged?(true)
                }
                guard let start = resizeStart else { return }
                var next = start
                next.width = snap(max(minSize.width, start.width + value.translation.width))
                next.height = snap(max(minSize.height, start.height + value.translation.height))
                frame = next.clamped(to: paperSize, minSize: minSize)
            }
            .onEnded { _ in
                resizeStart = nil
                onInteractionChanged?(false)
                onFrameChanged?()
            }
    }
}
