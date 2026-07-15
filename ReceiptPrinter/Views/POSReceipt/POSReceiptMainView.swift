import SwiftUI

struct POSReceiptMainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: POSReceiptSession

    @FocusState private var focusedField: Field?
    @State private var previewPayload: PreviewPayload?
    @State private var isPrinting = false

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    private enum Field: Hashable {
        case code, name, quantity, amount
    }

    private var template: POSReceiptTemplate? {
        // Prefer live editing copy when它就是当前使用模板，方便改字号后立刻预览。
        if let editing = session.editingTemplate,
           editing.id == session.settings.activeTemplateId || editing.id == session.activeTemplate?.id {
            return editing
        }
        return session.activeTemplate
    }

    var body: some View {
        HSplitView {
            formColumn
                .frame(minWidth: 280, idealWidth: 340)

            listColumn
                .frame(minWidth: 320)
        }
        .padding(8)
        .background(
            Button("") { Task { await printTicket() } }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
        )
        .sheet(item: $previewPayload) { payload in
            BitmapPrintPreviewView(image: payload.image)
                .frame(width: 420, height: 640)
        }
        .onAppear {
            if let t = template {
                session.loadImages(for: t)
            }
            if template?.enableCode == true {
                focusedField = .code
            } else {
                focusedField = .name
            }
        }
    }

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text("当前使用模板")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(template?.name ?? "（请先到「模板」页创建或选用）")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let t = template {
                if t.enableCode {
                    labeledField("编号") {
                        TextField("英文或数字", text: Binding(
                            get: { session.draftCode },
                            set: { session.draftCode = session.sanitizeCode($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .code)
                        .onSubmit { handleCodeSubmit() }
                    }
                }

                labeledField("项目名称") {
                    TextField("必填", text: $session.draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                        .onSubmit { handleNameSubmit() }
                }

                if t.enableQuantity {
                    labeledField("数量") {
                        TextField("数量", text: $session.draftQuantity)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .quantity)
                            .onSubmit { handleQuantitySubmit() }
                    }
                }

                if t.enableAmount {
                    labeledField("金额") {
                        TextField("金额", text: $session.draftAmount)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .amount)
                            .onSubmit { handleAmountSubmit() }
                    }
                }

                if t.hasElement(field: .quantitySubtotal)
                    || t.hasElement(field: .amountSubtotal)
                    || t.hasElement(field: .surcharge)
                    || t.hasElement(field: .amountTotal) {
                    Divider()
                    Text("汇总").font(.headline)
                    if t.hasElement(field: .quantitySubtotal) {
                        HStack {
                            Text("数量小计")
                            Spacer()
                            Text(session.quantitySubtotalText).monospacedDigit()
                        }
                    }
                    if t.hasElement(field: .amountSubtotal) {
                        HStack {
                            Text("金额小计")
                            Spacer()
                            Text(session.amountSubtotalText).monospacedDigit()
                        }
                    }
                    if t.hasElement(field: .surcharge) {
                        labeledField("附加费") {
                            TextField("0.00", text: $session.surcharge)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    if t.hasElement(field: .amountTotal) {
                        HStack {
                            Text("金额合计").fontWeight(.semibold)
                            Spacer()
                            Text(session.amountTotalText)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }
                }
            }

            Spacer()

            if !session.message.isEmpty {
                Text(session.message)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            HStack {
                Button("预览") { previewTicket() }
                    .disabled(template == nil || session.lineItems.isEmpty || isPrinting)
                Button(isPrinting ? "打印中…" : "打印 (⌘↩)") {
                    Task { await printTicket() }
                }
                .disabled(template == nil || session.lineItems.isEmpty || isPrinting)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("条目").font(.headline)
                Spacer()
                if session.selectedItemId != nil {
                    Button("删除选中") { deleteSelected() }
                }
                Button("清空") {
                    session.lineItems = []
                    session.selectedItemId = nil
                    session.clearDraft()
                    session.nextAutoCode = 1
                }
            }

            if session.lineItems.isEmpty {
                ContentUnavailableView("暂无条目", systemImage: "list.bullet", description: Text("在左侧输入后回车添加"))
            } else {
                List(selection: $session.selectedItemId) {
                    ForEach(session.lineItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                if let t = template, t.enableCode {
                                    Text(item.code.isEmpty ? "—" : item.code)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 72, alignment: .leading)
                                }
                                Text(item.name).lineLimit(1)
                                Spacer()
                                if let t = template, t.enableQuantity {
                                    Text(item.quantity).monospacedDigit()
                                }
                                if let t = template, t.enableAmount {
                                    Text(item.amount).monospacedDigit()
                                        .frame(width: 64, alignment: .trailing)
                                }
                            }
                            .font(.body)
                        }
                        .tag(item.id)
                        .contentShape(Rectangle())
                    }
                }
                .onChange(of: session.selectedItemId) { _, id in
                    guard let id, let item = session.lineItems.first(where: { $0.id == id }) else { return }
                    session.draftCode = item.code
                    session.draftName = item.name
                    session.draftQuantity = item.quantity
                    session.draftAmount = item.amount
                }
            }
        }
        .padding()
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Enter flow

    private func handleCodeSubmit() {
        guard let t = template else { return }
        if session.selectedItemId != nil {
            commitEditToSelected()
            return
        }
        let code = session.draftCode.trimmingCharacters(in: .whitespaces)
        if t.excelBookmarkData != nil, !code.isEmpty {
            do {
                let table = try POSExcelLookupService.loadTable(for: t)
                session.excelRowCount = table.rows.count
                // Persist refreshed headers if needed
                if var updated = session.templates.first(where: { $0.id == t.id }) {
                    updated.excelCachedHeaders = table.headers
                    session.store.saveMeta(updated)
                    session.reloadTemplates()
                }
                if let hit = POSExcelLookupService.lookup(code: code, table: table, map: t.excelColumnMap) {
                    session.draftCode = hit.code
                    if !hit.name.isEmpty { session.draftName = hit.name }
                    if t.enableQuantity, !hit.quantity.isEmpty { session.draftQuantity = hit.quantity }
                    if t.enableAmount, !hit.amount.isEmpty { session.draftAmount = hit.amount }
                    focusFirstEmpty(after: .code)
                    return
                }
            } catch {
                session.message = error.localizedDescription
            }
            focusFirstEmpty(after: .code)
            return
        }
        // No excel or empty code → jump to name
        focusedField = .name
    }

    private func handleNameSubmit() {
        guard let t = template else { return }
        if session.selectedItemId != nil {
            commitEditToSelected()
            return
        }
        if t.enableQuantity {
            focusedField = .quantity
        } else if t.enableAmount {
            focusedField = .amount
        } else {
            finishLineItem()
        }
    }

    private func handleQuantitySubmit() {
        guard let t = template else { return }
        if session.selectedItemId != nil {
            commitEditToSelected()
            return
        }
        if t.enableAmount {
            focusedField = .amount
        } else {
            finishLineItem()
        }
    }

    private func handleAmountSubmit() {
        if session.selectedItemId != nil {
            commitEditToSelected()
            return
        }
        finishLineItem()
    }

    private func focusFirstEmpty(after field: Field) {
        guard let t = template else { return }
        let order: [(Field, Bool, String)] = [
            (.code, t.enableCode, session.draftCode),
            (.name, true, session.draftName),
            (.quantity, t.enableQuantity, session.draftQuantity),
            (.amount, t.enableAmount, session.draftAmount)
        ]
        var passed = field == .code ? false : true
        if field == .code { passed = true }
        for (f, enabled, value) in order {
            if f == field { passed = true; continue }
            guard passed, enabled else { continue }
            // code may be empty (auto); skip emptiness for code when deciding complete
            if f == .code { continue }
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                focusedField = f
                return
            }
        }
        // All filled → finish
        if isDraftComplete(template: t) {
            finishLineItem()
        } else {
            focusedField = .name
        }
    }

    private func isDraftComplete(template t: POSReceiptTemplate) -> Bool {
        let nameOK = !session.draftName.trimmingCharacters(in: .whitespaces).isEmpty
        let qtyOK = !t.enableQuantity || !session.draftQuantity.trimmingCharacters(in: .whitespaces).isEmpty
        let amtOK = !t.enableAmount || !session.draftAmount.trimmingCharacters(in: .whitespaces).isEmpty
        return nameOK && qtyOK && amtOK
    }

    private func finishLineItem() {
        guard let t = template else { return }
        guard isDraftComplete(template: t) else {
            focusFirstEmpty(after: .code)
            return
        }
        var code = session.draftCode.trimmingCharacters(in: .whitespaces)
        if t.enableCode, code.isEmpty {
            code = "\(session.nextAutoCode)"
            session.nextAutoCode += 1
        }
        let item = POSLineItem(
            code: code,
            name: session.draftName.trimmingCharacters(in: .whitespaces),
            quantity: session.draftQuantity.trimmingCharacters(in: .whitespaces),
            amount: session.draftAmount.trimmingCharacters(in: .whitespaces)
        )
        session.lineItems.append(item)
        session.clearDraft()
        session.selectedItemId = nil
        session.message = "已添加条目"
        focusedField = t.enableCode ? .code : .name
    }

    private func commitEditToSelected() {
        guard let id = session.selectedItemId,
              let idx = session.lineItems.firstIndex(where: { $0.id == id }),
              let t = template else { return }
        var item = session.lineItems[idx]
        if t.enableCode { item.code = session.sanitizeCode(session.draftCode) }
        item.name = session.draftName
        if t.enableQuantity { item.quantity = session.draftQuantity }
        if t.enableAmount { item.amount = session.draftAmount }
        session.lineItems[idx] = item
        session.message = "条目已更新"
    }

    private func deleteSelected() {
        guard let id = session.selectedItemId else { return }
        session.lineItems.removeAll { $0.id == id }
        session.selectedItemId = nil
        session.clearDraft()
    }

    private func previewTicket() {
        guard let t = template, !session.lineItems.isEmpty else { return }
        let result = POSReceiptPrintComposer.compose(
            template: t,
            items: session.lineItems,
            surcharge: session.surcharge,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig
        )
        previewPayload = PreviewPayload(image: result.previewImage)
    }

    private func printTicket() async {
        guard let t = template, !session.lineItems.isEmpty else {
            session.message = "请先添加条目"
            return
        }
        guard appState.settings.selectedPrinterName != nil else {
            appState.lastError = "请先在设置中选择打印机"
            return
        }
        isPrinting = true
        defer { isPrinting = false }
        let autoEl = t.elements.first { $0.kind == .autoNumber }
        let ticketNumber = autoEl?.autoNumberStart
        let result = POSReceiptPrintComposer.compose(
            template: t,
            items: session.lineItems,
            surcharge: session.surcharge,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig,
            ticketAutoNumber: ticketNumber
        )
        let statusPollingWasActive = appState.gmailSync.isRunning
        if let record = await appState.runDiagnosticPrint(
            artifacts: result.artifacts,
            statusPollingWasActive: statusPollingWasActive
        ) {
            if record.transportError == nil {
                session.message = "已发送到打印机"
                // Advance template auto-number start if present
                if var updated = session.templates.first(where: { $0.id == t.id }),
                   let idx = updated.elements.firstIndex(where: { $0.kind == .autoNumber }) {
                    let start = updated.elements[idx].autoNumberStart
                    updated.elements[idx].autoNumberStart = QuickPrintAutoNumber.format(start: start, offset: 1)
                    session.store.saveMeta(updated)
                    session.reloadTemplates()
                }
            } else {
                session.message = "打印失败: \(record.transportError ?? "")"
            }
        }
    }
}
