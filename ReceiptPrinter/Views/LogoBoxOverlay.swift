import SwiftUI
import AppKit

/// Draggable / resizable logo box on the sequence-print canvas (above body, under placeholders).
struct LogoBoxOverlay: View {
    var image: NSImage
    @Binding var frame: SequencePlaceholderFrame
    @Binding var isSelected: Bool
    var paperSize: CGSize
    var onDelete: () -> Void

    @State private var dragStart: SequencePlaceholderFrame?
    @State private var resizeStart: SequencePlaceholderFrame?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: frame.width, height: frame.height)
                .opacity(0.95)

            RoundedRectangle(cornerRadius: 3)
                .stroke(isSelected ? Color.orange : Color.orange.opacity(0.45), lineWidth: isSelected ? 2 : 1)

            if isSelected {
                HStack {
                    Text("Logo")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    Spacer(minLength: 0)
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help("删除 Logo")
                }
                .padding(4)

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Circle()
                            .fill(Color.orange)
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
                frame = next.clamped(to: paperSize, minSize: CGSize(width: 36, height: 24))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil { resizeStart = frame }
                guard let start = resizeStart else { return }
                var next = start
                next.width = start.width + value.translation.width
                next.height = start.height + value.translation.height
                frame = next.clamped(to: paperSize, minSize: CGSize(width: 36, height: 24))
            }
            .onEnded { _ in resizeStart = nil }
    }
}
