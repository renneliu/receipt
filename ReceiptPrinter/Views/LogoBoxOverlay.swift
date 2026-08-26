import SwiftUI
import AppKit

/// Draggable / resizable logo box on the sequence-print canvas (above body, under placeholders).
/// Uses the same bottom-right resize handle as `PlaceholderBoxOverlay` (macOS-reliable).
struct LogoBoxOverlay: View {
    var title: String = "Logo"
    var image: NSImage
    @Binding var frame: SequencePlaceholderFrame
    @Binding var isSelected: Bool
    var paperSize: CGSize
    /// Called after a corner-resize ends so the parent can sync scalePercent.
    var onFrameChanged: (() -> Void)? = nil
    /// true while drag/resize is active so the parent can skip expensive live recomposes.
    var onInteractionChanged: ((Bool) -> Void)? = nil
    var onDelete: () -> Void
    /// When true, hide the logo bitmap (shown by live print underlay) and keep only chrome.
    var chromeOnly: Bool = false
    /// When true, position drag is disabled (resize still allowed).
    var isLocked: Bool = false
    /// `additive` is true when ⌘ is held (toggle multi-select).
    var onSelectRequest: ((_ additive: Bool) -> Void)? = nil
    /// When set, position drag reports translation from gesture start (parent moves selection).
    var onTranslateChanged: ((CGSize) -> Void)? = nil
    var onTranslateEnded: (() -> Void)? = nil
    /// When set, drag/resize use this named coordinate space (avoids center-position feedback loop).
    var gestureCoordinateSpaceName: String? = nil

    @State private var dragStart: SequencePlaceholderFrame?
    @State private var resizeStart: SequencePlaceholderFrame?
    @State private var isResizing = false

    private let minBox = CGSize(width: 36, height: 24)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !chromeOnly {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: frame.width, height: frame.height)
                    .opacity(0.95)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.001))
            }

            RoundedRectangle(cornerRadius: 3)
                .stroke(
                    isSelected ? Color.orange : Color.orange.opacity(chromeOnly ? 0.35 : 0.45),
                    lineWidth: isSelected ? 2 : 1
                )

            if isSelected {
                HStack {
                    HStack(spacing: 2) {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
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
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 10, height: 10)
                            .padding(6)
                            .contentShape(Rectangle())
                            .gesture(resizeGesture)
                            .help(L10n.ui("拖动右下角调整大小"))
                    }
                }
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .offset(x: frame.x, y: frame.y)
        .gesture(dragGesture)
        .simultaneousGesture(
            TapGesture().onEnded {
                if let onSelectRequest {
                    onSelectRequest(NSEvent.modifierFlags.contains(.command))
                } else {
                    isSelected = true
                }
            }
        )
    }

    private func makeDragGesture(minimumDistance: CGFloat) -> DragGesture {
        if let name = gestureCoordinateSpaceName {
            return DragGesture(minimumDistance: minimumDistance, coordinateSpace: .named(name))
        }
        return DragGesture(minimumDistance: minimumDistance)
    }

    private var dragGesture: some Gesture {
        makeDragGesture(minimumDistance: 3)
            .onChanged { value in
                if isResizing || resizeStart != nil { return }
                if dragStart == nil {
                    if let onSelectRequest {
                        if !isSelected { onSelectRequest(false) }
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
                next.x = start.x + value.translation.width
                next.y = start.y + value.translation.height
                frame = next.clamped(to: paperSize, minSize: minBox)
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
        makeDragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeStart == nil {
                    isResizing = true
                    resizeStart = frame
                    dragStart = nil
                    onInteractionChanged?(true)
                }
                guard let start = resizeStart else { return }
                var next = start
                next.width = max(minBox.width, start.width + value.translation.width)
                next.height = max(minBox.height, start.height + value.translation.height)
                next.x = start.x
                next.y = start.y
                frame = next.clamped(to: paperSize, minSize: minBox)
            }
            .onEnded { _ in
                resizeStart = nil
                isResizing = false
                onInteractionChanged?(false)
                onFrameChanged?()
            }
    }
}
