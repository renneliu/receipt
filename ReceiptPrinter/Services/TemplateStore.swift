import Foundation

final class TemplateStore {
    private let directory: URL

    init() {
        directory = AppPaths.subdirectory("Templates")
        seedSamplesIfNeeded()
    }

    func loadAll() -> [ReceiptTemplate] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ReceiptTemplate.self, from: data)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ template: ReceiptTemplate) {
        var t = template
        t.touch()
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        if let data = try? JSONEncoder().encode(t) {
            try? data.write(to: url)
        }
    }

    func delete(_ template: ReceiptTemplate) {
        let url = directory.appendingPathComponent("\(template.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    private func seedSamplesIfNeeded() {
        #if APPSTORE
        // Store: no bundled legacy templates — users create their own.
        return
        #else
        let existing = loadAll()
        for template in SampleTemplates.all {
            if let match = existing.first(where: { $0.name == template.name }) {
                var updated = template
                updated.id = match.id
                let forceUpdate = template.name == "电影票 (Orpheum)"
                if forceUpdate || updated.blocks != match.blocks {
                    save(updated)
                }
            } else {
                save(template)
            }
        }
        #endif
    }
}

enum SampleTemplates {
    static var all: [ReceiptTemplate] {
        [salesReceipt, orderReceiptWithQR, orpheumMovieTicket]
    }

    static var salesReceipt: ReceiptTemplate {
        ReceiptTemplate(
            name: "简易销售小票",
            paperWidth: 80,
            blocks: [
                .text("{{shopName}}", align: .center, size: .double, bold: true),
                .text("{{address}}", align: .center),
                .text("电话: {{phone}}", align: .center),
                .spacer(1),
                .line(),
                TemplateBlock(type: .table, tableColumns: ["name", "qty", "price"], dataSource: "items"),
                .line(),
                .text("小计: {{subtotal}}", align: .right),
                .text("合计: {{total}}", align: .right, bold: true),
                .spacer(2),
                .text("谢谢惠顾!", align: .center)
            ]
        )
    }

    static var orderReceiptWithQR: ReceiptTemplate {
        ReceiptTemplate(
            name: "电影票订单小票",
            paperWidth: 80,
            blocks: [
                .text("{{cinemaName}}", align: .center, size: .double, bold: true),
                .line(),
                .text("影片: {{movieName}}"),
                .text("场次: {{showTime}}"),
                .text("影厅: {{hall}}"),
                .text("座位: {{seats}}"),
                .text("订单号: {{orderNo}}"),
                .line(),
                .text("合计: ¥{{total}}", align: .right, bold: true),
                .spacer(1),
                .qr("{{qrContent}}"),
                .spacer(1),
                .text("请出示二维码入场", align: .center)
            ]
        )
    }

    /// Orpheum-style cinema admission ticket (two tickets per receipt).
    static var orpheumMovieTicket: ReceiptTemplate {
        ReceiptTemplate(
            name: "电影票 (Orpheum)",
            paperWidth: 80,
            blocks: [
                .row(left: "{{venueName}}", right: "Cinema ", highlight: "{{hallNumber}}", size: .double, bold: true),
                .text("{{movieTitle}}", align: .center, size: .double, bold: true),
                .text("{{showDateTime}}"),
                .row(left: "ADMIT", right: "{{ticketType}} {{ticketPrice}}"),
                .text("{{ticketCode}}", align: .center),
                .text("--------------------------", align: .center),
                .row(left: "{{venueName}}", right: "Cinema ", highlight: "{{hallNumber}}", size: .double, bold: true),
                .text("{{movieTitle}}", align: .center, size: .double, bold: true),
                .text("{{showDateTime}}"),
                .row(left: "ADMIT", right: "{{ticketType}} {{ticketPrice}}"),
                .barcode("{{barcode}}", height: 80, width: 2, printHRI: false),
                .text("{{barcodeLabel}}", align: .center)
            ]
        )
    }

    static var previewDataSales: [String: String] {
        [
            "shopName": "示例商店",
            "address": "上海市示例路 100 号",
            "phone": "021-12345678",
            "subtotal": "¥37.00",
            "total": "¥37.00",
            "items": #"[[{"name":"商品A","qty":"2","price":"¥24.00"},{"name":"商品B","qty":"1","price":"¥13.00"}]]"#
        ]
    }

    static var previewDataOrder: [String: String] {
        [
            "cinemaName": "示例影城",
            "movieName": "示例电影",
            "showTime": "2026-07-01 19:30",
            "hall": "3号厅",
            "seats": "5排6座",
            "orderNo": "ORD123456",
            "total": "45.00",
            "qrContent": "https://example.com/ticket/ORD123456"
        ]
    }

    static var previewDataMovieTicket: [String: String] {
        MovieTicketData.sample.renderedDictionary()
    }
}
