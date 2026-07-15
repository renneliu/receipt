import SwiftUI

/// Draggable / resizable auto-number stamp on the Quick Print canvas.
struct AutoNumberBoxOverlay: View {
    @Binding var frame: SequencePlaceholderFrame
    @Binding var isSelected: Bool
    var previewText: String
    var fontSize: CGFloat
    var paperSize: CGSize
    var onFrameChanged: (() -> Void)? = nil

    @State private var dragStart: SequencePlaceholderFrame?
    @State private var resizeStart: SequencePlaceholderFrame?

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.purple.opacity(isSelected ? 0.14 : 0.08))
            RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? Color.purple : Color.purple.opacity(0.5), lineWidth: isSelected ? 2 : 1)

            VStack(alignment: .leading, spacing: 2) {
                if isSelected {
                    Text("自动编号")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.purple)
                }
                Text(previewText.isEmpty ? " " : previewText)
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(4)

            if isSelected {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color.purple)
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

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isSelected = true
                if dragStart == nil { dragStart = frame }
                guard let start = dragStart else { return }
                var next = start
                next.x = start.x + value.translation.width
                next.y = start.y + value.translation.height
                frame = next.clamped(to: paperSize, minSize: CGSize(width: 36, height: 22))
            }
            .onEnded { _ in
                dragStart = nil
                onFrameChanged?()
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isSelected = true
                if resizeStart == nil { resizeStart = frame }
                guard let start = resizeStart else { return }
                var next = start
                next.width = start.width + value.translation.width
                next.height = start.height + value.translation.height
                frame = next.clamped(to: paperSize, minSize: CGSize(width: 36, height: 22))
            }
            .onEnded { _ in
                resizeStart = nil
                onFrameChanged?()
            }
    }
}
