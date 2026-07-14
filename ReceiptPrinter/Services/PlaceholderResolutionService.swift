import Foundation

struct TemplateDataContext {
    var manual: [String: String] = [:]
    var settings: AppSettings = .load()
    var gmailFields: [String: String] = [:]
    var movieFields: [String: String] = [:]
}

enum PlaceholderResolutionService {
    /// Resolves all placeholder keys for a template from layered sources.
    static func resolve(template: ReceiptTemplate, context: TemplateDataContext) -> [String: String] {
        var result = template.defaultData
        result.merge(context.manual) { _, new in new }

        for (key, value) in context.gmailFields {
            result[key] = value
            result["gmail.\(key)"] = value
        }
        for (key, value) in context.movieFields {
            result[key] = value
            result["movie.\(key)"] = value
        }

        if MovieTicketData.isMovieTicketTemplate(template) {
            let ticket = MovieTicketData.from(dictionary: result)
            var adjusted = ticket
            if adjusted.adDurationMinutes == 0 {
                adjusted.adDurationMinutes = context.settings.defaultAdvertisingMinutes
            }
            result.merge(adjusted.renderedDictionary()) { _, new in new }
        }

        for key in template.allPlaceholderKeys() {
            if result[key] == nil {
                result[key] = ""
            }
        }
        return result
    }

    /// Computes show end time from start + ad + runtime (minutes).
    static func computedEndTime(
        startISO: String?,
        adMinutes: Int,
        runtimeMinutes: Int,
        calendar: Calendar = .current
    ) -> Date? {
        guard let startISO else { return nil }
        let ticket = MovieTicketData.from(dictionary: [
            "showStartISO": startISO,
            "adDurationMinutes": String(adMinutes),
            "movieDurationMinutes": String(runtimeMinutes)
        ])
        return ticket.showEndTime
    }
}
