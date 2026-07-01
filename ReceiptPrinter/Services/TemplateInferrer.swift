import Foundation

enum TemplateInferrer {
    struct InferenceResult {
        let block: TemplateBlock
        let confidence: Double
    }

    static func inferPlaceholder(for block: TemplateBlock, observation: TextObservation) -> InferenceResult {
        let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let placeholder = matchPlaceholder(text) {
            var b = block
            b.content = "{{\(placeholder)}}"
            b.confidence = 0.85
            return InferenceResult(block: b, confidence: 0.85)
        }
        if block.align == .center && block.size == .double {
            var b = block
            b.content = "{{shopName}}"
            return InferenceResult(block: b, confidence: 0.75)
        }
        return InferenceResult(block: block, confidence: Double(observation.confidence))
    }

    static func inferFieldName(block: TemplateBlock, text: String) -> TemplateBlock {
        var b = block
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.contains("合计") || label.contains("总计") {
            b.content = "合计: {{total}}"
        } else if label.contains("影片") || label.contains("电影") {
            b.content = "影片: {{movieName}}"
        } else if label.contains("场次") || label.contains("时间") {
            b.content = "场次: {{showTime}}"
        } else if label.contains("座位") {
            b.content = "座位: {{seats}}"
        } else if label.contains("订单") {
            b.content = "订单号: {{orderNo}}"
        } else if label.contains("影厅") || label.contains("厅") {
            b.content = "影厅: {{hall}}"
        }
        return b
    }

    static func buildTemplate(from blocks: [RecognizedBlock], name: String = "识别模板") -> ReceiptTemplate {
        ReceiptTemplate(name: name, paperWidth: 80, blocks: blocks.map(\.block))
    }

    private static func matchPlaceholder(_ text: String) -> String? {
        if text.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return "date" }
        if text.range(of: #"^\d{1,2}:\d{2}"#, options: .regularExpression) != nil { return "time" }
        if text.contains("¥") || text.range(of: #"^\d+\.\d{2}$"#, options: .regularExpression) != nil { return "total" }
        if text.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil { return "phone" }
        if text.range(of: #"^[A-Z0-9]{6,}$"#, options: .regularExpression) != nil { return "orderNo" }
        return nil
    }
}
