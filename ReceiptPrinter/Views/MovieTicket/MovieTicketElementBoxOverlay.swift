import AppKit
import SwiftUI

/// Stable paper coordinate space for movie-ticket canvas gestures.
/// Local DragGesture + center `.position` feedback-loops (height oscillates) when the
/// view moves under the finger; paper-space deltas stay stable.
enum MovieTicketCanvasSpace {
    static let name = "movieTicketPaper"
}

/// Draggable / resizable box for movie-ticket template canvas elements.
///
/// The frame is the printable region: left edge = print start X; overflow is clipped
/// (or wrapped within the box when `singleLineClip` is off).
///
/// Resize uses bottom-right handle; drag/resize use paper coordinate space so
/// updating frame does not invert gesture translation.
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
    /// When true, preview text stays on one line (matches print single-line clip).
    var singleLineClip: Bool = false
    /// When true, preview text is already print-wrapped; render each line with
    /// `lineLimit(1)` so SwiftUI does not soft-wrap again (must match main preview).
    var printAccurateLines: Bool = false
    /// Line box height for print-accurate previews (Font A × height scale in paper points).
    var printLineHeight: CGFloat = 0
    /// Minimum resize size (defaults match legacy; print placeholders may use a shorter min height).
    var minSize: CGSize = CGSize(width: 12, height: 22)
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
    @State private var isResizing = false

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

    private var previewLineLimit: Int {
        if singleLineClip { return 1 }
        return max(1, Int((frame.height / 11).rounded(.down)))
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
                    .lineLimit(previewLineLimit)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(multilineAlignment)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
                    .padding(.horizontal, 2)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(accent.opacity(isSelected ? 0.14 : 0.08))
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? accent : accent.opacity(0.5), lineWidth: isSelected ? 2 : 1)

                if printAccurateLines {
                    // Pre-wrapped by fitTextToElementBox — one Text per print line, no soft wrap.
                    let lines = previewText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    let rowH = printLineHeight > 0
                        ? printLineHeight
                        : max(11, fontSize * 1.15)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: min(fontSize, rowH * 0.85), design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, minHeight: rowH, maxHeight: rowH, alignment: frameAlignment)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                } else {
                    Text(previewText.isEmpty ? " " : previewText)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(multilineAlignment)
                        .lineLimit(previewLineLimit)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
                        .padding(4)
                        .clipped()
                }
            }

            if isSelected {
                // Overlay only — does not change text wrap / scale.
                labelChip
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Spacer(minLength: 0)
                        Circle()
                            .fill(accent)
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
        // Top-leading placement keeps x/y stable while resizing (unlike center `.position`).
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

    private var labelChip: some View {
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

    private func snap(_ value: CGFloat) -> CGFloat {
        if NSEvent.modifierFlags.contains(.option) { return value }
        guard gridEnabled, gridSize > 0 else { return value }
        return (value / gridSize).rounded() * gridSize
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(MovieTicketCanvasSpace.name))
            .onChanged { value in
                if isResizing || resizeStart != nil { return }
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
                // Paper-space translation is stable even while the view offset updates.
                let paperDelta = CGSize(
                    width: value.translation.width,
                    height: value.translation.height
                )
                if let onTranslateChanged {
                    onTranslateChanged(paperDelta)
                    return
                }
                guard let start = dragStart else { return }
                var next = start
                next.x = snap(start.x + paperDelta.width)
                next.y = snap(start.y + paperDelta.height)
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
        DragGesture(minimumDistance: 1, coordinateSpace: .named(MovieTicketCanvasSpace.name))
            .onChanged { value in
                if let onSelectRequest {
                    if !isSelected { onSelectRequest(false) }
                } else {
                    isSelected = true
                }
                if resizeStart == nil {
                    isResizing = true
                    resizeStart = frame
                    dragStart = nil
                    onInteractionChanged?(true)
                }
                guard let start = resizeStart else { return }
                var next = start
                next.width = snap(max(minSize.width, start.width + value.translation.width))
                next.height = snap(max(minSize.height, start.height + value.translation.height))
                // Keep top-left fixed while resizing.
                next.x = start.x
                next.y = start.y
                frame = next.clamped(to: paperSize, minSize: minSize)
            }
            .onEnded { _ in
                resizeStart = nil
                isResizing = false
                onInteractionChanged?(false)
                onFrameChanged?()
            }
    }
}
