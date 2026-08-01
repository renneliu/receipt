import Foundation

struct MovieSearchResult: Identifiable, Codable, Equatable {
    var id: Int
    var title: String
    var originalTitle: String?
    var year: String
    var runtimeMinutes: Int
    /// AU-preferred classification (e.g. `M`, `PG`, `MA15+`).
    var certification: String?
    var posterURL: String?
}

protocol MovieMetadataService {
    func search(title: String) async throws -> [MovieSearchResult]
    func runtime(for movieID: Int) async throws -> Int?
}

struct TMDBMovieMetadataProvider: MovieMetadataService {
    private let apiKey: String
    private let cache: MovieRuntimeCache

    init(settings: AppSettings, cache: MovieRuntimeCache = .shared) {
        self.apiKey = settings.tmdbAPIKey
        self.cache = cache
    }

    func search(title: String) async throws -> [MovieSearchResult] {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Prefer zh-CN; if empty, retry en-US (English titles often miss under zh-CN query).
        var results = try await searchOnce(query: trimmed, language: "zh-CN")
        if results.isEmpty {
            results = try await searchOnce(query: trimmed, language: "en-US")
        }
        return results
    }

    private func searchOnce(query: String, language: String) async throws -> [MovieSearchResult] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/movie")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        guard let url = components.url else { throw TMDBError.requestFailed }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TMDBError.requestFailed
        }
        let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
        var results: [MovieSearchResult] = []
        for item in decoded.results.prefix(12) {
            let details = try await movieDetails(for: item.id)
            let runtime = details.runtime ?? item.runtime ?? 0
            if runtime > 0 {
                cache.store(movieID: item.id, runtime: runtime)
            }
            results.append(MovieSearchResult(
                id: item.id,
                title: item.title,
                originalTitle: item.originalTitle,
                year: yearString(from: item.releaseDate),
                runtimeMinutes: runtime,
                certification: details.certification,
                posterURL: posterPath(item.posterPath)
            ))
        }
        // Keep zero-runtime rows so the user can still pick a title; sheet shows "— 分钟".
        return results
    }

    func runtime(for movieID: Int) async throws -> Int? {
        if let cached = cache.runtime(for: movieID) { return cached }
        let details = try await movieDetails(for: movieID)
        if let runtime = details.runtime, runtime > 0 {
            cache.store(movieID: movieID, runtime: runtime)
            return runtime
        }
        return nil
    }

    func certification(for movieID: Int) async throws -> String? {
        try await movieDetails(for: movieID).certification
    }

    private struct MovieDetails {
        var runtime: Int?
        var certification: String?
    }

    private func movieDetails(for movieID: Int) async throws -> MovieDetails {
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(movieID)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "zh-CN"),
            URLQueryItem(name: "append_to_response", value: "release_dates")
        ]
        guard let url = components.url else { throw TMDBError.requestFailed }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return MovieDetails(runtime: nil, certification: nil)
        }
        let detail = try JSONDecoder().decode(TMDBMovieDetail.self, from: data)
        return MovieDetails(
            runtime: detail.runtime,
            certification: Self.preferredCertification(from: detail.releaseDates)
        )
    }

    /// Prefer AU cinema ratings (M / PG / MA15+…), then NZ / GB / US.
    static func preferredCertification(from payload: TMDBReleaseDatesPayload?) -> String? {
        guard let countries = payload?.results, !countries.isEmpty else { return nil }
        let preferred = ["AU", "NZ", "GB", "US"]
        for code in preferred {
            if let cert = firstNonEmptyCertification(in: countries.first { $0.iso3166 == code }) {
                return cert
            }
        }
        for country in countries {
            if let cert = firstNonEmptyCertification(in: country) {
                return cert
            }
        }
        return nil
    }

    private static func firstNonEmptyCertification(in country: TMDBReleaseCountry?) -> String? {
        guard let country else { return nil }
        for entry in country.releaseDates {
            let c = entry.certification.trimmingCharacters(in: .whitespacesAndNewlines)
            if !c.isEmpty { return c }
        }
        return nil
    }

    private func yearString(from date: String?) -> String {
        guard let date, date.count >= 4 else { return "—" }
        return String(date.prefix(4))
    }

    private func posterPath(_ path: String?) -> String? {
        guard let path else { return nil }
        return "https://image.tmdb.org/t/p/w92\(path)"
    }
}

enum TMDBError: LocalizedError {
    case missingAPIKey
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请先在设置中配置 TMDB API Key"
        case .requestFailed: return "TMDB 请求失败"
        }
    }
}

private struct TMDBSearchResponse: Decodable {
    let results: [TMDBSearchItem]
}

private struct TMDBSearchItem: Decodable {
    let id: Int
    let title: String
    let originalTitle: String?
    let releaseDate: String?
    let posterPath: String?
    let runtime: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, runtime
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
    }
}

private struct TMDBMovieDetail: Decodable {
    let runtime: Int?
    let releaseDates: TMDBReleaseDatesPayload?

    enum CodingKeys: String, CodingKey {
        case runtime
        case releaseDates = "release_dates"
    }
}

struct TMDBReleaseDatesPayload: Decodable {
    let results: [TMDBReleaseCountry]
}

struct TMDBReleaseCountry: Decodable {
    let iso3166: String
    let releaseDates: [TMDBReleaseDateEntry]

    enum CodingKeys: String, CodingKey {
        case iso3166 = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

struct TMDBReleaseDateEntry: Decodable {
    let certification: String
}

final class MovieRuntimeCache {
    static let shared = MovieRuntimeCache()

    private let fileURL: URL
    private var cache: [String: Int] = [:]

    init() {
        fileURL = AppPaths.applicationSupportRoot.appendingPathComponent("movie_runtime_cache.json")
        load()
    }

    func runtime(for movieID: Int) -> Int? {
        cache[String(movieID)]
    }

    func store(movieID: Int, runtime: Int) {
        cache[String(movieID)] = runtime
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        cache = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
