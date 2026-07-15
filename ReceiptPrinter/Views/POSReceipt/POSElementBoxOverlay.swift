import SwiftUI

/// Draggable / resizable box for POS template canvas elements (with optional grid snap).
struct POSElementBoxOverlay: View {
    @Binding var frame: SequencePlaceholderFrame
    @Binding var isSelected: Bool
    var title: String
    var previewText: String
    var fontSize: CGFloat
    var paperSize: CGSize
    var gridEnabled: Bool
    var gridSize: CGFloat
    var accent: Color = .blue
    /// When true, only selection chrome is drawn — ink comes from the live print preview underlay.
    var chromeOnly: Bool = false
    /// When true, position drag is disabled (resize still allowed).
    var isLocked: Bool = false
    var onFrameChanged: (() -> Void)? = nil
    /// true while drag/resize is active so the parent can skip expensive live recomposes.
    var onInteractionChanged: ((Bool) -> Void)? = nil

    @State private var dragStart: SequencePlaceholderFrame?
    @State private var resizeStart: SequencePlaceholderFrame?

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
                        .lineLimit(4)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .padding(4)
            }

            if isSelected {
                if chromeOnly {
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
        .onTapGesture { isSelected = true }
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        guard gridEnabled, gridSize > 0 else { return value }
        return (value / gridSize).rounded() * gridSize
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isSelected = true
                guard !isLocked else { return }
                if dragStart == nil {
                    dragStart = frame
                    onInteractionChanged?(true)
                }
                guard let start = dragStart else { return }
                var next = start
                next.x = snap(start.x + value.translation.width)
                next.y = snap(start.y + value.translation.height)
                frame = next.clamped(to: paperSize, minSize: CGSize(width: 36, height: 22))
            }
            .onEnded { _ in
                guard dragStart != nil else { return }
                dragStart = nil
                onInteractionChanged?(false)
                onFrameChanged?()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isSelected = true
                if resizeStart == nil {
                    resizeStart = frame
                    onInteractionChanged?(true)
                }
                guard let start = resizeStart else { return }
                var next = start
                next.width = snap(max(36, start.width + value.translation.width))
                next.height = snap(max(22, start.height + value.translation.height))
                frame = next.clamped(to: paperSize, minSize: CGSize(width: 36, height: 22))
            }
            .onEnded { _ in
                resizeStart = nil
                onInteractionChanged?(false)
                onFrameChanged?()
            }
    }
}
