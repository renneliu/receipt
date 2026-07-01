import Foundation

/// Dedicated ESC/POS layout for Orpheum-style cinema tickets (matches reference receipt).
enum OrpheumTicketRenderer {
    static func renderESCPOS(data: [String: String], config: PrinterConfig) -> Data {
        let builder = ESCPOSBuilder(config: config).initialize()
        // #region agent log
        DebugLog.write(
            hypothesisId: "F",
            location: "OrpheumTicketRenderer.renderESCPOS",
            message: "dedicated renderer start",
            data: ["venue": data["venueName"] ?? "", "movie": data["movieTitle"] ?? ""]
        )
        // #endregion
        renderTicket(builder, data: data, includeBarcode: false)
        builder.align(.center).text("--------------------------").newline()
        renderTicket(builder, data: data, includeBarcode: true)
        return builder.cut().build()
    }

    private static func renderTicket(_ builder: ESCPOSBuilder, data: [String: String], includeBarcode: Bool) {
        let venue = data["venueName"] ?? ""
        let hall = data["hallNumber"] ?? ""
        let movie = data["movieTitle"] ?? ""
        let when = data["showDateTime"] ?? ""
        let ticketType = data["ticketType"] ?? ""
        let price = data["ticketPrice"] ?? ""

        builder.align(.left)
            .tableRowWithHighlight(
                left: venue,
                rightPrefix: "Cinema ",
                highlight: hall,
                leftBold: true,
                leftSize: .double
            )

        builder.align(.center)
            .bold(true)
            .applyTextSize(.double)
            .text(movie)
            .newline()
            .bold(false)
            .applyTextSize(.normal)
        // #region agent log
        DebugLog.write(
            hypothesisId: "G",
            location: "OrpheumTicketRenderer.renderTicket",
            message: "movie title size",
            data: ["title": String(movie.prefix(40)), "size": "double", "gsMode": "0x11"]
        )
        // #endregion

        builder.align(.left)
            .text(when)
            .newline()

        builder.tableRowWithHighlight(
            left: "ADMIT",
            rightPrefix: "\(ticketType) \(price)",
            highlight: "",
            leftBold: false,
            leftSize: .normal
        )

        if includeBarcode {
            let code = data["barcode"] ?? ""
            let label = data["barcodeLabel"] ?? ""
            builder.barcode(type: .code128, content: code, height: 80, width: 2, printHRI: false)
            builder.align(.center).text(label).newline()
        } else {
            builder.align(.center).text(data["ticketCode"] ?? "").newline()
        }
    }
}
