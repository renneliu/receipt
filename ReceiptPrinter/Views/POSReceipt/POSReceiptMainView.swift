import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct POSReceiptMainView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var session: POSReceiptSession

    @FocusState private var focusedField: POSDraftField?
    @State private var previewPayload: PreviewPayload?
    @State private var isPrinting = false
    @State private var showHistory = false
    @State private var isRefreshingExcel = false
    @State private var showLoadDraftSheet = false

    private struct PreviewPayload: Identifiable {
        let id = UUID()
        let image: NSImage
    }

    private var template: POSReceiptTemplate? {
        if let editing = session.editingTemplate,
           editing.id == session.settings.activeTemplateId || editing.id == session.activeTemplate?.id {
            return editing
        }
        return session.activeTemplate
    }

    private var hasExcelBound: Bool {
        template?.excelBookmarkData != nil
    }

    private var hasExcelCatalog: Bool {
        hasExcelBound && !session.excelCatalog.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            let excelHeight = min(220, max(140, geo.size.height * 0.28))
            VStack(spacing: 8) {
                HSplitView {
                    ScrollView {
                        formColumn
                    }
                    .frame(minWidth: 280, idealWidth: 340)

                    listColumn
                        .frame(minWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if hasExcelBound {
                    excelQuickPickSection
                        .frame(height: excelHeight)
                }
            }
        }
        .padding(8)
        .sheet(item: $previewPayload) { payload in
            BitmapPrintPreviewView(image: payload.image)
                .frame(width: 420, height: 640)
        }
        .sheet(isPresented: $showHistory) {
            printHistorySheet
        }
        .sheet(isPresented: $showLoadDraftSheet) {
            NamedDraftPickerSheet(
                title: L10n.ui("读取草稿"),
                module: "posReceipt",
                onLoad: { draft in
                    loadNamedDraft(draft)
                    showLoadDraftSheet = false
                },
                onClose: { showLoadDraftSheet = false }
            )
        }
        .onAppear {
            refreshExcelIfNeeded()
            focusInitialField()
        }
        .onChange(of: template?.id) { _, _ in
            refreshExcelIfNeeded()
            focusInitialField()
        }
        .onChange(of: session.lineItems) { _, _ in session.persistCartDraft() }
        .onChange(of: session.draftCode) { _, _ in session.persistCartDraft() }
        .onChange(of: session.draftName) { _, _ in session.persistCartDraft() }
        .onChange(of: session.draftQuantity) { _, _ in session.persistCartDraft() }
        .onChange(of: session.draftAmount) { _, _ in session.persistCartDraft() }
        .onChange(of: session.surcharge) { _, _ in session.persistCartDraft() }
        .onReceive(NotificationCenter.default.publisher(for: .receiptPrinterPersistWorkingDrafts)) { _ in
            session.persistCartDraft()
        }
        .onReceive(NotificationCenter.default.publisher(for: .receiptPrinterClearWorkingContent)) { _ in
            session.clearLineItemsForNextTicket(resetSurchargeFrom: session.activeTemplate)
            session.clearCartDraftDisk()
        }
    }

    // MARK: - Columns

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                Text(L10n.ui("当前使用模板"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(template?.name ?? L10n.ui("（请先到「模板」页创建或选用）"))
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if hasExcelBound {
                    HStack {
                        Text(template?.excelDisplayName ?? L10n.ui("已绑定 Excel"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(isRefreshingExcel ? L10n.ui("刷新中…") : L10n.ui("刷新已上传 Excel")) {
                            Task { await refreshExcelTapped() }
                        }
                        .controlSize(.small)
                        .disabled(isRefreshingExcel)
                    }
                    if !session.message.isEmpty {
                        Text(session.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let t = template {
                if t.enableCode {
                    labeledField(L10n.ui("编号")) {
                        TextField(L10n.ui("英文或数字"), text: Binding(
                            get: { session.draftCode },
                            set: { session.draftCode = session.sanitizeCode($0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .code)
                        .onSubmit { handleCodeSubmit() }
                    }
                }

                labeledField(L10n.ui("项目名称")) {
                    TextField(L10n.ui("必填"), text: $session.draftName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                        .onSubmit { handleNameSubmit() }
                }

                if t.enableQuantity {
                    labeledField(L10n.ui("数量")) {
                        TextField(L10n.ui("数量"), text: $session.draftQuantity)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .quantity)
                            .onSubmit { handleQuantitySubmit() }
                    }
                }

                if t.enableAmount {
                    labeledField(L10n.ui("金额")) {
                        TextField(L10n.ui("金额"), text: $session.draftAmount)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .amount)
                            .onSubmit { handleAmountSubmit() }
                    }
                }

                if t.hasElement(field: .quantitySubtotal)
                    || t.hasElement(field: .amountSubtotal)
                    || t.hasElement(field: .surcharge)
                    || t.hasElement(field: .amountTotal)
                    || t.hasElement(field: .itemCount) {
                    Divider()
                    Text(L10n.ui("汇总")).font(.headline)
                    if t.hasElement(field: .quantitySubtotal) {
                        HStack {
                            Text(L10n.ui("数量小计"))
                            Spacer()
                            Text(session.quantitySubtotalText).monospacedDigit()
                        }
                    }
                    if t.hasElement(field: .amountSubtotal) {
                        HStack {
                            Text(L10n.ui("金额小计"))
                            Spacer()
                            Text(session.amountSubtotalText).monospacedDigit()
                        }
                    }
                    if t.hasElement(field: .surcharge) {
                        labeledField(L10n.ui("附加费")) {
                            TextField("0.00", text: Binding(
                                get: { session.surcharge },
                                set: { session.setSurchargeManually($0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        if let pct = session.surchargePercentLabel {
                            Text("打印注释：(\(pct))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        surchargePercentButtons
                    }
                    if t.hasElement(field: .amountTotal) {
                        HStack {
                            Text(L10n.ui("金额合计")).fontWeight(.semibold)
                            Spacer()
                            Text(session.amountTotalText)
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                    }
                    if t.hasElement(field: .itemCount) {
                        HStack {
                            Text(L10n.ui("总计"))
                            Spacer()
                            Text(session.itemCountText).monospacedDigit()
                        }
                    }
                }
            }

            if !session.message.isEmpty {
                Text(session.message)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if template != nil {
                Group {
                    Text(L10n.ui("切纸位置")).font(.headline)
                    HStack(spacing: 10) {
                        Stepper(
                            "\(L10n.ui("切纸前走纸")) \(cutFeedLines) \(L10n.ui("行"))",
                            value: Binding(
                                get: { cutFeedLines },
                                set: { setCutFeedLines($0) }
                            ),
                            in: 0...40
                        )
                        Button(L10n.ui("恢复默认")) {
                            setCutFeedLines(appState.settings.printerConfig.feedLinesBeforeCut)
                        }
                        .controlSize(.small)
                    }
                    Text(L10n.ui("控制打印结束后到切刀之间的空白；越小越省纸，过小可能裁到票面。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(L10n.ui("预览")) { previewTicket() }
                    .disabled(template == nil || session.lineItems.isEmpty || isPrinting)
                Button(isPrinting ? L10n.ui("打印中…") : L10n.ui("打印 (⌘↩)")) {
                    Task { await printTicket() }
                }
                .disabled(template == nil || session.lineItems.isEmpty || isPrinting)
                .keyboardShortcut(.return, modifiers: .command)
                Button(L10n.ui("保存草稿")) {
                    saveNamedDraft()
                }
                Button(L10n.ui("读取草稿")) {
                    showLoadDraftSheet = true
                }
                Button(L10n.ui("打印记录")) { showHistory = true }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var cutFeedLines: Int {
        template?.resolvedFeedLinesBeforeCut(config: appState.settings.printerConfig)
            ?? appState.settings.printerConfig.feedLinesBeforeCut
    }

    private func setCutFeedLines(_ value: Int) {
        let clamped = max(0, min(40, value))
        guard let id = template?.id else { return }
        session.updateTemplateMeta(id: id) { $0.feedLinesBeforeCut = clamped }
    }

    private var surchargePercentButtons: some View {
        let options: [(label: String, fraction: Double)] = [
            (L10n.ui("小计 10%"), 0.10),
            (L10n.ui("小计 20%"), 0.20),
            (L10n.ui("小计 50%"), 0.50),
            (L10n.ui("小计 100%"), 1.00)
        ]
        return HStack(spacing: 6) {
            ForEach(options, id: \.label) { option in
                Button(option.label) {
                    session.applySurchargePercent(option.fraction)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.ui("条目")).font(.headline)
                if session.editingLineItemId != nil {
                    Text(L10n.ui("（编辑中）"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if session.editingLineItemId != nil {
                    Button(L10n.ui("完成编辑")) {
                        commitEditToSelected()
                        session.endEditingLineItem()
                        session.clearDraft()
                        focusInitialField()
                    }
                }
                if session.selectedItemId != nil {
                    Button(L10n.ui("删除选中")) { deleteSelected() }
                }
                Button(L10n.ui("清空")) {
                    session.lineItems = []
                    session.endEditingLineItem()
                    session.clearDraft()
                    session.nextAutoCode = 1
                    session.prefersNameFieldForNextLine = false
                    focusInitialField()
                }
            }

            if session.lineItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(L10n.ui("暂无条目"))
                        .font(.headline)
                    Text(L10n.ui("在左侧输入后回车添加"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 12)
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
                        .listRowBackground(
                            session.editingLineItemId == item.id
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                        .onTapGesture {
                            guard let t = template else { return }
                            session.beginEditingLineItem(item, template: t)
                        }
                    }
                }
                .onChange(of: session.selectedItemId) { _, id in
                    guard let id,
                          let item = session.lineItems.first(where: { $0.id == id }),
                          let t = template else { return }
                    if session.editingLineItemId != id {
                        session.beginEditingLineItem(item, template: t)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var excelQuickPickSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.ui("Excel 快捷添加"))
                    .font(.headline)
                Button(isRefreshingExcel ? L10n.ui("刷新中…") : L10n.ui("刷新")) {
                    Task { await refreshExcelTapped() }
                }
                .controlSize(.small)
                .disabled(isRefreshingExcel)
                Spacer()
                if hasExcelCatalog {
                    Text(
                        L10n.current == .chinese
                            ? "第 \(session.excelCatalogPage + 1) / \(session.excelCatalogPageCount) 页"
                            : "Page \(session.excelCatalogPage + 1) / \(session.excelCatalogPageCount)"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        session.excelCatalogPage = max(0, session.excelCatalogPage - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(session.excelCatalogPage <= 0)
                    Button {
                        session.excelCatalogPage = min(session.excelCatalogPageCount - 1, session.excelCatalogPage + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(session.excelCatalogPage >= session.excelCatalogPageCount - 1)
                }
            }

            if hasExcelCatalog {
                let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(session.excelCatalogPageEntries) { entry in
                            Button(entry.buttonTitle) {
                                applyExcelCatalogEntry(entry)
                            }
                            .buttonStyle(.bordered)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text(L10n.ui("暂无快捷项。请确认「项目名称」列已映射，或点「刷新已上传 Excel」。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Excel

    private func refreshExcelIfNeeded() {
        guard let t = template else { return }
        session.loadImages(for: t)
        session.reloadExcelCatalog(for: t)
    }

    private func refreshExcelTapped() async {
        isRefreshingExcel = true
        defer { isRefreshingExcel = false }
        _ = await session.refreshBoundExcel()
    }

    private func applyExcelCatalogEntry(_ entry: POSExcelCatalogEntry) {
        guard let t = template else { return }
        session.endEditingLineItem()
        session.applyDraft(from: entry.item, template: t)
        if session.isDraftComplete(template: t) {
            finishLineItem()
        } else {
            focusFirstEmptyField()
        }
    }

    // MARK: - Enter flow

    private func handleCodeSubmit() {
        deferSubmit { self.handleCodeSubmitDeferred() }
    }

    private func handleCodeSubmitDeferred() {
        guard let t = template else { return }
        if session.editingLineItemId != nil {
            commitEditToSelected()
            return
        }
        let code = session.draftCode.trimmingCharacters(in: .whitespaces)
        if t.excelBookmarkData != nil, !code.isEmpty {
            do {
                let table = try POSExcelLookupService.loadTable(for: t)
                session.excelRowCount = table.rows.count
                if var updated = session.templates.first(where: { $0.id == t.id }) {
                    updated.excelCachedHeaders = table.headers
                    session.store.saveMeta(updated)
                    session.reloadTemplates()
                }
                if let hit = POSExcelLookupService.lookup(code: code, table: table, map: t.excelColumnMap) {
                    session.applyDraft(from: hit, template: t)
                    focusFirstEmptyField()
                    return
                }
            } catch {
                session.message = error.localizedDescription
            }
            focusFirstEmptyField()
            return
        }
        focusedField = .name
    }

    private func handleNameSubmit() {
        deferSubmit { self.handleNameSubmitDeferred() }
    }

    private func handleNameSubmitDeferred() {
        guard let t = template else { return }
        if session.editingLineItemId != nil {
            commitEditToSelected()
            return
        }
        if session.isDraftComplete(template: t) {
            finishLineItem()
            return
        }
        if t.enableQuantity, session.draftQuantity.trimmingCharacters(in: .whitespaces).isEmpty {
            focusedField = .quantity
        } else if t.enableAmount, session.draftAmount.trimmingCharacters(in: .whitespaces).isEmpty {
            focusedField = .amount
        } else {
            finishLineItem()
        }
    }

    private func handleQuantitySubmit() {
        deferSubmit { self.handleQuantitySubmitDeferred() }
    }

    private func handleQuantitySubmitDeferred() {
        guard let t = template else { return }
        if session.editingLineItemId != nil {
            commitEditToSelected()
            return
        }
        if session.isDraftComplete(template: t) {
            finishLineItem()
            return
        }
        if t.enableAmount, session.draftAmount.trimmingCharacters(in: .whitespaces).isEmpty {
            focusedField = .amount
        } else {
            finishLineItem()
        }
    }

    private func handleAmountSubmit() {
        deferSubmit { self.handleAmountSubmitDeferred() }
    }

    private func handleAmountSubmitDeferred() {
        if session.editingLineItemId != nil {
            commitEditToSelected()
            return
        }
        finishLineItem()
    }

    /// Let IME / TextField binding commit before reading draft values.
    private func deferSubmit(_ action: @escaping () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private func focusFirstEmptyField() {
        guard let t = template else { return }
        if let empty = session.firstEmptyDraftField(template: t) {
            focusedField = empty
            return
        }
        focusedField = POSDraftField.lastEnabled(template: t)
    }

    private func focusInitialField() {
        guard let t = template else { return }
        if session.prefersNameFieldForNextLine {
            focusedField = .name
        } else if t.enableCode {
            focusedField = .code
        } else {
            focusedField = .name
        }
    }

    private func focusAfterLineAdded(template t: POSReceiptTemplate) {
        if session.prefersNameFieldForNextLine {
            focusedField = .name
        } else if t.enableCode {
            focusedField = .code
        } else {
            focusedField = .name
        }
    }

    private func finishLineItem() {
        guard let t = template else { return }
        guard session.editingLineItemId == nil else {
            commitEditToSelected()
            return
        }
        guard session.isDraftComplete(template: t) else {
            focusFirstEmptyField()
            return
        }
        let rawCode = session.draftCode.trimmingCharacters(in: .whitespaces)
        var code = rawCode
        var usedAutoCode = false
        if t.enableCode, code.isEmpty {
            code = "\(session.nextAutoCode)"
            usedAutoCode = true
            session.nextAutoCode += 1
            session.prefersNameFieldForNextLine = true
        }
        let item = POSLineItem(
            code: code,
            name: session.draftName.trimmingCharacters(in: .whitespaces),
            quantity: session.draftQuantity.trimmingCharacters(in: .whitespaces),
            amount: session.draftAmount.trimmingCharacters(in: .whitespaces)
        )
        session.lineItems.append(item)
        session.prepareNextLineDraft(template: t)
        session.endEditingLineItem()
        session.message = usedAutoCode && t.enableCode
            ? "已添加条目（编号 \(code)）"
            : L10n.ui("已添加条目")
        focusAfterLineAdded(template: t)
    }

    private func commitEditToSelected() {
        let editId = session.editingLineItemId ?? session.selectedItemId
        guard let id = editId,
              let idx = session.lineItems.firstIndex(where: { $0.id == id }),
              let t = template else { return }
        var item = session.lineItems[idx]
        if t.enableCode { item.code = session.sanitizeCode(session.draftCode) }
        item.name = session.draftName
        if t.enableQuantity { item.quantity = session.draftQuantity }
        if t.enableAmount { item.amount = session.draftAmount }
        session.lineItems[idx] = item
        session.message = L10n.ui("条目已更新")
    }

    private func deleteSelected() {
        let id = session.editingLineItemId ?? session.selectedItemId
        guard let id else { return }
        session.lineItems.removeAll { $0.id == id }
        session.endEditingLineItem()
        session.clearDraft()
        focusInitialField()
    }

    private func saveNamedDraft() {
        let name = "草稿 \(Date().formatted(date: .abbreviated, time: .shortened))"
        session.persistCartDraft()
        let cart = POSCartDraft(
            lineItems: session.lineItems,
            draftCode: session.draftCode,
            draftName: session.draftName,
            draftQuantity: session.draftQuantity,
            draftAmount: session.draftAmount,
            surcharge: session.surcharge,
            surchargePercentLabel: session.surchargePercentLabel,
            nextAutoCode: session.nextAutoCode,
            prefersNameFieldForNextLine: session.prefersNameFieldForNextLine,
            activeTemplateId: session.settings.activeTemplateId,
            editingLineItemId: session.editingLineItemId
        )
        let preview = session.lineItems.map(\.name).filter { !$0.isEmpty }.joined(separator: "、")
        _ = NamedWorkingDraftStore.savePOSDraft(name: name, previewText: preview, cart: cart)
        session.message = L10n.ui("草稿已保存")
    }

    private func loadNamedDraft(_ draft: NamedWorkingDraft) {
        guard let cart = NamedWorkingDraftStore.loadPOSCart(id: draft.id) else {
            session.message = L10n.ui("暂无草稿")
            return
        }
        session.lineItems = cart.lineItems
        session.draftCode = cart.draftCode
        session.draftName = cart.draftName
        session.draftQuantity = cart.draftQuantity
        session.draftAmount = cart.draftAmount
        session.surcharge = cart.surcharge
        session.surchargePercentLabel = cart.surchargePercentLabel
        session.nextAutoCode = max(1, cart.nextAutoCode)
        session.prefersNameFieldForNextLine = cart.prefersNameFieldForNextLine
        if let id = cart.activeTemplateId, session.templates.contains(where: { $0.id == id }) {
            session.settings.activeTemplateId = id
            session.settings.save()
            if let t = session.templates.first(where: { $0.id == id }) {
                session.loadImages(for: t)
            }
        }
        if let editId = cart.editingLineItemId, session.lineItems.contains(where: { $0.id == editId }) {
            session.editingLineItemId = editId
            session.selectedItemId = editId
        } else {
            session.endEditingLineItem()
        }
        session.persistCartDraft()
        session.message = L10n.ui("已读取草稿")
    }

    private var printHistorySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.ui("打印记录")).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.ui("清理全部"), role: .destructive) {
                    session.clearPrintHistory()
                }
                .disabled(session.printHistory.isEmpty)
                Button(L10n.ui("关闭")) { showHistory = false }
                    .keyboardShortcut(.cancelAction)
            }
            if session.printHistory.isEmpty {
                ContentUnavailableView(L10n.ui("暂无记录"), systemImage: "clock", description: Text(L10n.ui("成功打印后会自动保存在此")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(session.printHistory) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.templateName).font(.headline)
                                Spacer()
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(record.itemSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text("合计 \(record.amountTotalText)")
                                .font(.caption.monospacedDigit())
                            HStack {
                                Button(L10n.ui("载入条目")) {
                                    session.loadPrintHistory(record)
                                    showHistory = false
                                    session.message = L10n.ui("已载入历史条目")
                                }
                                Button(L10n.ui("重新打印")) {
                                    Task {
                                        showHistory = false
                                        await reprintHistory(record)
                                    }
                                }
                                Button(L10n.ui("导出 PDF")) { exportHistoryPDF(record) }
                                Spacer()
                                Button(L10n.ui("删除"), role: .destructive) {
                                    session.deletePrintHistory(id: record.id)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
    }

    private func previewTicket() {
        guard let t = template, !session.lineItems.isEmpty else { return }
        let result = POSReceiptPrintComposer.compose(
            template: t,
            items: session.lineItems,
            surcharge: session.surcharge,
            surchargePercentLabel: session.surchargePercentLabel,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig
        )
        previewPayload = PreviewPayload(image: result.previewImage)
    }

    private func printTicket() async {
        await printCurrentTicket(clearAfterSuccess: true)
    }

    private func reprintHistory(_ record: POSPrintHistoryRecord) async {
        guard template != nil else {
            session.message = L10n.ui("请先选择模板")
            return
        }
        session.loadPrintHistory(record)
        await printCurrentTicket(clearAfterSuccess: true)
    }

    private func printCurrentTicket(clearAfterSuccess: Bool) async {
        guard let t = template, !session.lineItems.isEmpty else {
            session.message = L10n.ui("请先添加条目")
            return
        }
        guard appState.settings.selectedPrinterName != nil else {
            appState.lastError = L10n.ui("请先在设置中选择打印机")
            return
        }
        isPrinting = true
        defer { isPrinting = false }
        let itemsSnapshot = session.lineItems
        let surchargeSnapshot = session.surcharge
        let percentSnapshot = session.surchargePercentLabel
        let autoEl = t.elements.first { $0.kind == .autoNumber }
        let ticketNumber = autoEl?.autoNumberStart
        let result = POSReceiptPrintComposer.compose(
            template: t,
            items: itemsSnapshot,
            surcharge: surchargeSnapshot,
            surchargePercentLabel: percentSnapshot,
            backgroundImage: session.backgroundImage,
            logoImages: session.logoImages,
            config: appState.settings.printerConfig,
            ticketAutoNumber: ticketNumber
        )
        if let record = await appState.runDiagnosticPrint(
            artifacts: result.artifacts,
            statusPollingWasActive: false
        ) {
            if record.transportError == nil {
                session.recordSuccessfulPrint(
                    template: t,
                    items: itemsSnapshot,
                    surcharge: surchargeSnapshot,
                    surchargePercentLabel: percentSnapshot,
                    previewPNG: result.artifacts.pngData
                )
                if var updated = session.templates.first(where: { $0.id == t.id }),
                   let idx = updated.elements.firstIndex(where: { $0.kind == .autoNumber }) {
                    let start = updated.elements[idx].autoNumberStart
                    updated.elements[idx].autoNumberStart = QuickPrintAutoNumber.format(start: start, offset: 1)
                    session.store.saveMeta(updated)
                    session.reloadTemplates()
                }
                if clearAfterSuccess {
                    session.clearLineItemsForNextTicket(resetSurchargeFrom: t)
                    focusInitialField()
                }
                session.message = L10n.ui("已发送到打印机")
            } else {
                session.message = "打印失败: \(record.transportError ?? "")"
            }
        }
    }

    private func exportHistoryPDF(_ record: POSPrintHistoryRecord) {
        guard let image = NSImage(data: record.previewPNG) else {
            session.message = L10n.ui("无法导出：预览图缺失")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "POS小票-\(record.templateName)-\(Int(record.createdAt.timeIntervalSince1970)).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.writePDF(image: image, to: url)
            session.message = L10n.ui("已导出 PDF")
        } catch {
            session.message = "导出失败: \(error.localizedDescription)"
        }
    }

    private static func writePDF(image: NSImage, to url: URL) throws {
        // PDFKit handles bitmap→PDF orientation; manual CGContext + y-flip inverted the ticket.
        guard let page = PDFPage(image: image) else {
            throw NSError(domain: "POSPrintHistory", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L10n.ui("无法从预览图创建 PDF 页")
            ])
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        guard doc.write(to: url) else {
            throw NSError(domain: "POSPrintHistory", code: 2, userInfo: [
                NSLocalizedDescriptionKey: L10n.ui("写入 PDF 失败")
            ])
        }
    }
}
