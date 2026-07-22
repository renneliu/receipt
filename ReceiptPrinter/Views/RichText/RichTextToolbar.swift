import AppKit
import SwiftUI

/// Formatting controls for the receipt editor; intended for the right-hand Form panel.
struct RichTextToolbar: View {
    @ObservedObject var controller: RichTextEditorController
    var columnsPerLine: Int = 48
    @Binding var fontSize: Double

    @State private var alignment: NSTextAlignment = .left

    private static let fontSizeOptions: [Double] = [
        10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 32, 36, 40, 44, 48, 56, 64, 72
    ]

    var body: some View {
        Group {
            HStack {
                Text(L10n.ui("字号"))
                Picker(L10n.ui("字号"), selection: $fontSize) {
                    ForEach(Self.fontSizeOptions, id: \.self) { size in
                        Text("\(Int(size))").tag(size)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .onChange(of: fontSize) { _, v in
                    controller.applyFontSize(CGFloat(v))
                }
            }

            HStack(spacing: 12) {
                Text(L10n.ui("样式"))
                Spacer()
                Button { controller.toggleBold() } label: { Image(systemName: "bold") }
                    .buttonStyle(.borderless)
                    .help(L10n.ui("粗体"))
                Button { controller.toggleItalic() } label: { Image(systemName: "italic") }
                    .buttonStyle(.borderless)
                    .help(L10n.ui("斜体"))
                Button { controller.toggleUnderline() } label: { Image(systemName: "underline") }
                    .buttonStyle(.borderless)
                    .help(L10n.ui("下划线"))
            }

            HStack {
                Text(L10n.ui("对齐"))
                Picker(L10n.ui("对齐"), selection: $alignment) {
                    Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                    Image(systemName: "text.alignright").tag(NSTextAlignment.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: alignment) { _, align in
                    controller.applyAlignment(align)
                }
            }

            Menu(L10n.ui("分割线")) {
                Button(L10n.ui("直线")) {
                    controller.insertDivider(style: .solid, columns: columnsPerLine)
                }
                Button(L10n.ui("虚线")) {
                    controller.insertDivider(style: .dashed, columns: columnsPerLine)
                }
            }

            Button(L10n.ui("清除格式")) { controller.clearFormatting() }
        }
    }
}
