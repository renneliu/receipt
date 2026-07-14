import AppKit
import SwiftUI

struct RichTextToolbar: View {
    @ObservedObject var controller: RichTextEditorController
    var columnsPerLine: Int = 48
    @Binding var fontSize: Double

    @State private var alignment: NSTextAlignment = .left
    @State private var textColor: Color = .primary

    private static let fontSizeOptions: [Double] = [
        10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 32, 36, 40, 44, 48, 56, 64, 72
    ]

    var body: some View {
        HStack(spacing: 8) {
            Picker("字号", selection: $fontSize) {
                ForEach(Self.fontSizeOptions, id: \.self) { size in
                    Text("\(Int(size))").tag(size)
                }
            }
            .frame(width: 80)
            .onChange(of: fontSize) { _, v in
                controller.applyFontSize(CGFloat(v))
            }

            Button { controller.toggleBold() } label: { Image(systemName: "bold") }
                .buttonStyle(.borderless)
                .help("粗体")

            Button { controller.toggleItalic() } label: { Image(systemName: "italic") }
                .buttonStyle(.borderless)
                .help("斜体")

            Button { controller.toggleUnderline() } label: { Image(systemName: "underline") }
                .buttonStyle(.borderless)
                .help("下划线")

            ColorPicker("颜色", selection: $textColor)
                .labelsHidden()
                .onChange(of: textColor) { _, color in
                    controller.applyForegroundColor(NSColor(color))
                }

            Picker("对齐", selection: $alignment) {
                Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                Image(systemName: "text.alignright").tag(NSTextAlignment.right)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
            .onChange(of: alignment) { _, align in
                controller.applyAlignment(align)
            }

            Menu("分割线") {
                Button("直线") {
                    controller.insertDivider(style: .solid, columns: columnsPerLine)
                }
                Button("虚线") {
                    controller.insertDivider(style: .dashed, columns: columnsPerLine)
                }
            }

            Button("清除格式") { controller.clearFormatting() }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
