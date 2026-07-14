import Foundation

struct MovieSearchResult: Identifiable, Codable, Equatable {
    var id: Int
    var title: String
    var originalTitle: String?
    var year: String
    var runtimeMinutes: Int
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
        let query = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let url = URL(string: "https://api.themoviedb.org/3/search/movie?api_key=\(apiKey)&query=\(query)&language=zh-CN")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TMDBError.requestFailed
        }
        let decoded = try JSONDecoder().decode(TMDBSearchResponse.self, from: data)
        var results: [MovieSearchResult] = []
        for item in decoded.results.prefix(12) {
            let runtime = try await runtime(for: item.id) ?? item.runtime ?? 0
            cache.store(movieID: item.id, runtime: runtime)
            results.append(MovieSearchResult(
                id: item.id,
                title: item.title,
                originalTitle: item.originalTitle,
                year: yearString(from: item.releaseDate),
                runtimeMinutes: runtime,
                posterURL: posterPath(item.posterPath)
            ))
        }
        return results.filter { $0.runtimeMinutes > 0 }
    }

    func runtime(for movieID: Int) async throws -> Int? {
        if let cached = cache.runtime(for: movieID) { return cached }
        guard !apiKey.isEmpty else { throw TMDBError.missingAPIKey }
        let url = URL(string: "https://api.themoviedb.org/3/movie/\(movieID)?api_key=\(apiKey)&language=zh-CN")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let detail = try JSONDecoder().decode(TMDBMovieDetail.self, from: data)
        if let runtime = detail.runtime, runtime > 0 {
            cache.store(movieID: movieID, runtime: runtime)
            return runtime
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
}

final class MovieRuntimeCache {
    static let shared = MovieRuntimeCache()

    private let fileURL: URL
    private var cache: [String: Int] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ReceiptPrinter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("movie_runtime_cache.json")
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
