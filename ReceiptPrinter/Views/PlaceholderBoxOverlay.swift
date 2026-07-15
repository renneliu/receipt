import SwiftUI

/// Draggable / resizable placeholder boxes layered over the sequence-print paper canvas.
struct PlaceholderBoxOverlay: View {
    @Binding var placeholders: [SequencePlaceholder]
    @Binding var selectedID: UUID?
    var values: [String: String]
    var paperSize: CGSize
    var printerConfig: PrinterConfig
    var fontSize: CGFloat

    @State private var dragStarts: [UUID: SequencePlaceholderFrame] = [:]
    @State private var resizeStarts: [UUID: SequencePlaceholderFrame] = [:]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(placeholders) { box in
                boxView(for: box)
            }
        }
        .frame(width: paperSize.width, height: paperSize.height, alignment: .topLeading)
        // Hit-test only the boxes themselves (no full-bleed blocker).
        .allowsHitTesting(!placeholders.isEmpty)
    }

    @ViewBuilder
    private func boxView(for box: SequencePlaceholder) -> some View {
        let selected = selectedID == box.id
        let preview = SequenceLayoutComposer.previewText(
            value: values[box.bindingKey] ?? "{{\(box.bindingKey)}}",
            frame: box.frame,
            config: printerConfig,
            fontSize: fontSize,
            paperWidthPoints: paperSize.width
        )

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(selected ? 0.12 : 0.06))
            RoundedRectangle(cornerRadius: 3)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.55), lineWidth: selected ? 2 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 2) {
                    Text(box.bindingKey)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Button {
                            deletePlaceholder(id: box.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .symbolRenderingMode(.hierarchical)
                        }
                        .buttonStyle(.plain)
                        .help("删除此占位框")
                    }
                }
                Text(preview.isEmpty ? " " : preview)
                    .font(.system(size: min(14, fontSize * 0.45), design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(4)

            if selected {
                resizeHandle
                    .gesture(resizeGesture(id: box.id))
            }
        }
        .frame(width: box.frame.width, height: box.frame.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .position(
            x: box.frame.x + box.frame.width / 2,
            y: box.frame.y + box.frame.height / 2
        )
        // Don't use highPriorityGesture here — it steals clicks from the delete button.
        .gesture(dragGesture(id: box.id))
        .onTapGesture {
            selectedID = box.id
        }
    }

    private var resizeHandle: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .padding(2)
            }
        }
    }

    private func index(of id: UUID) -> Int? {
        placeholders.firstIndex(where: { $0.id == id })
    }

    private func deletePlaceholder(id: UUID) {
        placeholders.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = nil
        }
        dragStarts[id] = nil
        resizeStarts[id] = nil
    }

    private func dragGesture(id: UUID) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let i = index(of: id) else { return }
                if selectedID != id { selectedID = id }
                if dragStarts[id] == nil {
                    dragStarts[id] = placeholders[i].frame
                }
                guard let start = dragStarts[id] else { return }
                var frame = start
                frame.x = start.x + value.translation.width
                frame.y = start.y + value.translation.height
                placeholders[i].frame = frame.clamped(to: paperSize)
            }
            .onEnded { _ in
                dragStarts[id] = nil
            }
    }

    private func resizeGesture(id: UUID) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard let i = index(of: id) else { return }
                if resizeStarts[id] == nil {
                    resizeStarts[id] = placeholders[i].frame
                }
                guard let start = resizeStarts[id] else { return }
                var frame = start
                frame.width = start.width + value.translation.width
                frame.height = start.height + value.translation.height
                placeholders[i].frame = frame.clamped(to: paperSize)
            }
            .onEnded { _ in
                resizeStarts[id] = nil
            }
    }
}
